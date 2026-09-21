// 独立 WGC 诊断：只读取捕获帧，不修改 Codex、系统配置或其他应用。
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#define WINVER 0x0A00
#define NTDDI_VERSION 0x0A000006
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <d3d11.h>
#include <dxgi.h>
#include <shellapi.h>
#ifdef __MINGW32__
// 当前 MinGW 头文件将 boolean 和 BYTE 都映射为 unsigned char；跳过未使用的重复模板。
#define ____FIReference_1_boolean_INTERFACE_DEFINED__
#endif
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.graphics.imaging.h>
#include <wrl/client.h>
#include <atomic>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include "wgc_readback.h"

namespace Capture = ABI::Windows::Graphics::Capture;
namespace Foundation = ABI::Windows::Foundation;
namespace Imaging = ABI::Windows::Graphics::Imaging;
namespace Direct3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using Microsoft::WRL::ComPtr;
using FrameEvent = Foundation::ITypedEventHandler<Capture::Direct3D11CaptureFramePool*, IInspectable*>;
using BitmapOperation = Foundation::IAsyncOperation<Imaging::SoftwareBitmap*>;
using BitmapCompleted = Foundation::IAsyncOperationCompletedHandler<Imaging::SoftwareBitmap*>;
using Activation = HRESULT (WINAPI*)(HSTRING, REFIID, void**);
Activation activate_factory = RoGetActivationFactory;

struct Failure { HRESULT code; const char* stage; };
void check(HRESULT code, const char* stage) { if (FAILED(code)) throw Failure{code, stage}; }

template<class Interface>
ComPtr<Interface> factory(const wchar_t* name) {
    HSTRING text = nullptr;
    check(WindowsCreateString(name, static_cast<UINT32>(wcslen(name)), &text), "WindowsCreateString");
    ComPtr<Interface> result;
    const auto hr = activate_factory(text, __uuidof(Interface), reinterpret_cast<void**>(result.GetAddressOf()));
    WindowsDeleteString(text);
    check(hr, "RoGetActivationFactory");
    return result;
}

void close_object(IUnknown* value) {
    if (!value) return;
    ComPtr<Foundation::IClosable> closable;
    if (SUCCEEDED(value->QueryInterface(IID_PPV_ARGS(&closable)))) closable->Close();
}

struct State {
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE converted = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::atomic<unsigned> events{0}, frames{0};
    std::atomic<bool> selected{false};
    bool success = false, conversion_timeout = false;
    HRESULT error = S_OK;
    const char* stage = "waiting_for_frame";
    DWORD callback_thread = 0, conversion_thread = 0;
    INT32 width = 0, height = 0;
    Imaging::BitmapPixelFormat bitmap_format{};
    Imaging::BitmapAlphaMode bitmap_alpha{};
    unsigned rgb_min = 255, rgb_max = 0;
    ULONGLONG started = GetTickCount64(), first_frame_ms = 0, conversion_ms = 0;
    std::string mode;
    ~State() { CloseHandle(done); CloseHandle(converted); }
};

template<class Interface>
class Delegate : public Interface {
    std::atomic<ULONG> references{1};
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id == __uuidof(IUnknown) || id == __uuidof(IAgileObject) || id == __uuidof(Interface)) {
            *out = static_cast<Interface*>(this); AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        const auto count = --references;
        if (!count) delete this;
        return count;
    }
protected:
    virtual ~Delegate() = default;
};

class Completion final : public Delegate<BitmapCompleted> {
    std::shared_ptr<State> state;
public:
    explicit Completion(std::shared_ptr<State> value) : state(std::move(value)) {}
    HRESULT STDMETHODCALLTYPE Invoke(BitmapOperation*, AsyncStatus) override {
        SetEvent(state->converted);
        return S_OK;
    }
};

void read_pixels(Direct3D::IDirect3DSurface* surface, State& state) {
    ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
    check(surface->QueryInterface(IID_PPV_ARGS(&access)), "surface_dxgi_access");
    ComPtr<ID3D11Texture2D> texture;
    check(access->GetInterface(IID_PPV_ARGS(&texture)), "surface_texture");
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    ComPtr<ID3D11Device> device;
    texture->GetDevice(&device);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> staging;
    check(device->CreateTexture2D(&desc, nullptr, &staging), "staging_texture");
    ComPtr<ID3D11DeviceContext> context;
    device->GetImmediateContext(&context);
    context->CopyResource(staging.Get(), texture.Get());
    D3D11_MAPPED_SUBRESOURCE data{};
    check(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &data), "map_pixels");
    for (UINT y = 0; y < desc.Height; ++y) {
        const auto* row = static_cast<const unsigned char*>(data.pData) + y * data.RowPitch;
        for (UINT x = 0; x < desc.Width; ++x) {
            for (UINT c = 0; c < 3; ++c) {
                const auto v = row[x * 4 + c];
                if (v < state.rgb_min) state.rgb_min = v;
                if (v > state.rgb_max) state.rgb_max = v;
            }
        }
    }
    context->Unmap(staging.Get(), 0);
}

void convert_frame(ComPtr<Capture::IDirect3D11CaptureFrame> frame, const std::shared_ptr<State>& state) {
    try {
        state->conversion_thread = GetCurrentThreadId();
        ComPtr<Direct3D::IDirect3DSurface> surface;
        check(frame->get_Surface(&surface), "get_surface");
        const auto start = GetTickCount64();
        ComPtr<Imaging::ISoftwareBitmap> bitmap;
        if (state->mode == "direct") {
            check(copy_wgc_surface(surface.Get(), Imaging::BitmapAlphaMode_Straight, &bitmap), "direct_surface_copy");
        } else {
        auto statics = factory<Imaging::ISoftwareBitmapStatics>(L"Windows.Graphics.Imaging.SoftwareBitmap");
        ComPtr<BitmapOperation> operation;
        check(statics->CreateCopyFromSurfaceAsync(surface.Get(), &operation), "CreateCopyFromSurfaceAsync");
        ComPtr<Completion> handler;
        handler.Attach(new Completion(state));
        check(operation->put_Completed(handler.Get()), "register_conversion_completed");
        // 有上限的等待使对照试验不会永久阻塞捕获回调。
        if (WaitForSingleObject(state->converted, 2000) != WAIT_OBJECT_0) {
            state->conversion_timeout = true;
            throw Failure{HRESULT_FROM_WIN32(WAIT_TIMEOUT), "conversion_wait_timeout"};
        }
        check(operation->GetResults(&bitmap), "conversion_GetResults");
        }
        check(bitmap->get_PixelWidth(&state->width), "bitmap_width");
        check(bitmap->get_PixelHeight(&state->height), "bitmap_height");
        check(bitmap->get_BitmapPixelFormat(&state->bitmap_format), "bitmap_format");
        check(bitmap->get_BitmapAlphaMode(&state->bitmap_alpha), "bitmap_alpha");
        state->conversion_ms = GetTickCount64() - start;
        read_pixels(surface.Get(), *state);
        state->success = state->width > 0 && state->height > 0 && state->rgb_max > state->rgb_min;
        state->stage = "conversion_and_pixels_complete";
        close_object(bitmap.Get());
    } catch (Failure error) {
        state->error = error.code; state->stage = error.stage;
    }
    close_object(frame.Get());
    SetEvent(state->done);
}

class FrameHandler final : public Delegate<FrameEvent> {
    std::shared_ptr<State> state;
public:
    explicit FrameHandler(std::shared_ptr<State> value) : state(std::move(value)) {}
    HRESULT STDMETHODCALLTYPE Invoke(Capture::IDirect3D11CaptureFramePool* pool, IInspectable*) override {
        ++state->events;
        ComPtr<Capture::IDirect3D11CaptureFrame> frame;
        if (FAILED(pool->TryGetNextFrame(&frame)) || !frame) return S_OK;
        ++state->frames;
        if (state->selected.exchange(true)) { close_object(frame.Get()); return S_OK; }
        state->first_frame_ms = GetTickCount64() - state->started;
        state->callback_thread = GetCurrentThreadId();
        if (state->mode == "worker") {
            // 持有帧引用并立即返回，转换在线程池以外的独立 MTA 线程进行。
            std::thread([frame, state = state]() {
                const auto hr = RoInitialize(RO_INIT_MULTITHREADED);
                if (SUCCEEDED(hr)) {
                    convert_frame(frame, state);
                    RoUninitialize();
                } else {
                    state->error = hr; state->stage = "worker_RoInitialize";
                    close_object(frame.Get()); SetEvent(state->done);
                }
            }).detach();
        } else if (state->mode == "callback" || state->mode == "direct" || state->mode == "shim") {
            convert_frame(frame, state);
        } else {
            ABI::Windows::Graphics::SizeInt32 size{};
            state->error = frame->get_ContentSize(&size);
            state->width = size.Width; state->height = size.Height;
            state->success = SUCCEEDED(state->error) && size.Width > 0 && size.Height > 0;
            state->stage = "frame_received";
            close_object(frame.Get()); SetEvent(state->done);
        }
        return S_OK;
    }
};

BOOL CALLBACK left_monitor(HMONITOR monitor, HDC, LPRECT rect, LPARAM result) {
    if (rect->left < 0) *reinterpret_cast<HMONITOR*>(result) = monitor;
    return TRUE;
}

int main(int argc, char** argv) {
    const std::string mode = argc > 1 ? argv[1] : "worker";
    const std::string target = argc > 2 ? argv[2] : "primary";
    const std::string driver = argc > 3 ? argv[3] : "hardware";
    if ((mode != "frame" && mode != "callback" && mode != "worker" && mode != "direct" && mode != "shim") ||
        (target != "primary" && target != "left" && target != "window") ||
        (driver != "hardware" && driver != "warp")) {
        std::fprintf(stderr, "Usage: wgc_probe [frame|callback|worker|direct|shim] [primary|left|window] [hardware|warp] [Explorer window title]\n");
        return 2;
    }
    auto state = std::make_shared<State>();
    state->mode = mode;
    try {
        if (mode == "shim") {
            wchar_t executable[32768]{};
            if (!GetModuleFileNameW(nullptr, executable, 32768)) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "get_probe_path"};
            const std::wstring path(executable);
            const auto library = path.substr(0, path.find_last_of(L"\\/") + 1) + L"codex-wgc-readback.dll";
            auto module = LoadLibraryW(library.c_str());
            if (!module) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "load_compatibility_library"};
            activate_factory = reinterpret_cast<Activation>(GetProcAddress(module, "WgcRoGetActivationFactory"));
            if (!activate_factory) throw Failure{E_NOINTERFACE, "compatibility_export"};
        }
        check(RoInitialize(RO_INIT_MULTITHREADED), "RoInitialize");
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        ComPtr<ID3D11Device> device;
        check(D3D11CreateDevice(nullptr, driver == "warp" ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
            nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, nullptr), "D3D11CreateDevice");
        ComPtr<IDXGIDevice> dxgi;
        check(device.As(&dxgi), "dxgi_device");
        ComPtr<IInspectable> inspectable;
        check(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), &inspectable), "CreateDirect3D11DeviceFromDXGIDevice");
        ComPtr<Direct3D::IDirect3DDevice> direct3d;
        check(inspectable.As(&direct3d), "winrt_device");
        auto interop = factory<IGraphicsCaptureItemInterop>(L"Windows.Graphics.Capture.GraphicsCaptureItem");
        ComPtr<Capture::IGraphicsCaptureItem> item;
        if (target == "window") {
            int wide_argc = 0;
            auto wide_argv = CommandLineToArgvW(GetCommandLineW(), &wide_argc);
            if (!wide_argv) throw Failure{E_OUTOFMEMORY, "parse_window_title"};
            const std::wstring title = wide_argc > 4 ? wide_argv[4] : L"";
            LocalFree(wide_argv);
            if (title.empty()) throw Failure{E_INVALIDARG, "window_title_required"};
            auto window = FindWindowW(L"CabinetWClass", title.c_str());
            if (!window || IsIconic(window)) throw Failure{E_INVALIDARG, "explorer_window_missing_or_minimized"};
            check(interop->CreateForWindow(window, IID_PPV_ARGS(&item)), "CreateForWindow");
        } else {
            auto monitor = MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY);
            if (target == "left") {
                monitor = nullptr;
                EnumDisplayMonitors(nullptr, nullptr, left_monitor, reinterpret_cast<LPARAM>(&monitor));
                if (!monitor) throw Failure{E_INVALIDARG, "left_monitor_missing"};
            }
            check(interop->CreateForMonitor(monitor, IID_PPV_ARGS(&item)), "CreateForMonitor");
        }
        ABI::Windows::Graphics::SizeInt32 size{};
        check(item->get_Size(&size), "capture_item_size");
        auto pool_factory = factory<Capture::IDirect3D11CaptureFramePoolStatics2>(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool");
        ComPtr<Capture::IDirect3D11CaptureFramePool> pool;
        check(pool_factory->CreateFreeThreaded(direct3d.Get(), static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(87), 2, size, &pool), "CreateFreeThreaded");
        ComPtr<FrameHandler> handler;
        handler.Attach(new FrameHandler(state));
        EventRegistrationToken token{};
        check(pool->add_FrameArrived(handler.Get(), &token), "add_FrameArrived");
        ComPtr<Capture::IGraphicsCaptureSession> session;
        check(pool->CreateCaptureSession(item.Get(), &session), "CreateCaptureSession");
        // 使用系统默认边框，不调用当前 Win10 上缺失的 IsBorderRequired。
        check(session->StartCapture(), "StartCapture");
        if (WaitForSingleObject(state->done, 6000) != WAIT_OBJECT_0) {
            state->error = HRESULT_FROM_WIN32(WAIT_TIMEOUT); state->stage = "capture_wait_timeout";
        }
        pool->remove_FrameArrived(token);
        close_object(session.Get());
        close_object(pool.Get());
    } catch (Failure error) { state->error = error.code; state->stage = error.stage; }
    std::printf("{\"mode\":\"%s\",\"target\":\"%s\",\"driver\":\"%s\",\"success\":%s,\"stage\":\"%s\",\"hresult\":\"0x%08lX\",\"events\":%u,\"frames\":%u,\"first_frame_ms\":%llu,\"conversion_timeout\":%s,\"conversion_ms\":%llu,\"callback_thread\":%lu,\"conversion_thread\":%lu,\"width\":%d,\"height\":%d,\"rgb_min\":%u,\"rgb_max\":%u}\n",
        mode.c_str(), target.c_str(), driver.c_str(), state->success ? "true" : "false", state->stage,
        static_cast<unsigned long>(state->error), state->events.load(), state->frames.load(), state->first_frame_ms,
        state->conversion_timeout ? "true" : "false", state->conversion_ms, state->callback_thread, state->conversion_thread,
        state->width, state->height, state->rgb_min, state->rgb_max);
    std::fprintf(stderr, "bitmap_format=%d bitmap_alpha=%d\n", int(state->bitmap_format), int(state->bitmap_alpha));
    return state->success ? 0 : 1;
}
