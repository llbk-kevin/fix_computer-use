// 当前 Win10 的局部兼容层：保持 WGC 捕获，仅替换 SoftwareBitmap 表面复制。
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#define WINVER 0x0A00
#define NTDDI_VERSION 0x0A000006
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <d3d11.h>
#ifdef __MINGW32__
#define ____FIReference_1_boolean_INTERFACE_DEFINED__
#endif
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.graphics.imaging.h>
#include <wrl/client.h>
#include <atomic>
#include <mutex>
#include <new>
#include "wgc_readback.h"

namespace Foundation = ABI::Windows::Foundation;
namespace Imaging = ABI::Windows::Graphics::Imaging;
namespace Streams = ABI::Windows::Storage::Streams;
namespace Direct3D = ABI::Windows::Graphics::DirectX::Direct3D11;
using Microsoft::WRL::ComPtr;
using Operation = Foundation::IAsyncOperation<Imaging::SoftwareBitmap*>;
using Completion = Foundation::IAsyncOperationCompletedHandler<Imaging::SoftwareBitmap*>;
constexpr HRESULT ClosedResult = static_cast<HRESULT>(0x80000013u); // RO_E_CLOSED
constexpr HRESULT AlreadyAssigned = static_cast<HRESULT>(0x80000018u); // E_ILLEGAL_DELEGATE_ASSIGNMENT

// 像素复制完成后才创建操作对象，因此完成通知不依赖 WGC 回调返回。
class CompletedBitmap final : public Operation, public IAsyncInfo {
    std::atomic<ULONG> references{1};
    std::mutex mutex;
    ComPtr<Imaging::ISoftwareBitmap> bitmap;
    ComPtr<Completion> completion;
    bool assigned = false, closed = false;
public:
    explicit CompletedBitmap(Imaging::ISoftwareBitmap* value) : bitmap(value) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id == __uuidof(IUnknown) || id == __uuidof(IInspectable) || id == __uuidof(IAgileObject) || id == __uuidof(Operation)) *out = static_cast<Operation*>(this);
        else if (id == __uuidof(IAsyncInfo)) *out = static_cast<IAsyncInfo*>(this);
        else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override { auto count = --references; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE GetIids(ULONG* count, IID** ids) override {
        if (!count || !ids) return E_POINTER;
        *count = 0; *ids = static_cast<IID*>(CoTaskMemAlloc(sizeof(IID) * 2));
        if (!*ids) return E_OUTOFMEMORY;
        (*ids)[0] = __uuidof(Operation); (*ids)[1] = __uuidof(IAsyncInfo); *count = 2; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeClassName(HSTRING* name) override {
        if (!name) return E_POINTER;
        *name = nullptr; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetTrustLevel(TrustLevel* level) override { if (!level) return E_POINTER; *level = BaseTrust; return S_OK; }
    HRESULT STDMETHODCALLTYPE put_Completed(Completion* value) override {
        ComPtr<Completion> notify;
        {
            std::lock_guard<std::mutex> guard(mutex);
            if (closed) return ClosedResult;
            if (assigned) return AlreadyAssigned;
            assigned = true; completion = value; notify = value;
        }
        // 在锁外通知，允许处理器立即调用 GetResults 或释放它自己的引用。
        if (notify) { AddRef(); notify->Invoke(this, static_cast<AsyncStatus>(1)); Release(); }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Completed(Completion** value) override {
        if (!value) return E_POINTER;
        std::lock_guard<std::mutex> guard(mutex);
        return completion.CopyTo(value);
    }
    HRESULT STDMETHODCALLTYPE GetResults(Imaging::ISoftwareBitmap** value) override {
        if (!value) return E_POINTER;
        *value = nullptr;
        std::lock_guard<std::mutex> guard(mutex);
        if (closed) return ClosedResult;
        return bitmap.CopyTo(value);
    }
    HRESULT STDMETHODCALLTYPE get_Id(UINT32* value) override { if (!value) return E_POINTER; *value = 1; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_Status(AsyncStatus* value) override { if (!value) return E_POINTER; *value = static_cast<AsyncStatus>(1); return S_OK; }
    HRESULT STDMETHODCALLTYPE get_ErrorCode(HRESULT* value) override { if (!value) return E_POINTER; *value = S_OK; return S_OK; }
    HRESULT STDMETHODCALLTYPE Cancel() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Close() override {
        std::lock_guard<std::mutex> guard(mutex);
        closed = true; bitmap.Reset(); completion.Reset(); return S_OK;
    }
};

class BitmapStatics final : public Imaging::ISoftwareBitmapStatics {
    std::atomic<ULONG> references{1};
    ComPtr<Imaging::ISoftwareBitmapStatics> original;
    HRESULT copy(Direct3D::IDirect3DSurface* surface, Imaging::BitmapAlphaMode alpha, Operation** result) {
        if (!result) return E_POINTER;
        *result = nullptr;
        ComPtr<Imaging::ISoftwareBitmap> bitmap;
        const auto hr = copy_wgc_surface(surface, alpha, &bitmap);
        if (FAILED(hr)) return hr;
        auto operation = new (std::nothrow) CompletedBitmap(bitmap.Get());
        if (!operation) return E_OUTOFMEMORY;
        *result = operation;
        return S_OK;
    }
public:
    explicit BitmapStatics(Imaging::ISoftwareBitmapStatics* value) : original(value) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id == __uuidof(IUnknown) || id == __uuidof(IInspectable) || id == __uuidof(IAgileObject) || id == __uuidof(Imaging::ISoftwareBitmapStatics)) {
            *out = static_cast<Imaging::ISoftwareBitmapStatics*>(this); AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override { auto count = --references; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE GetIids(ULONG* count, IID** ids) override { return original->GetIids(count, ids); }
    HRESULT STDMETHODCALLTYPE GetRuntimeClassName(HSTRING* name) override { return original->GetRuntimeClassName(name); }
    HRESULT STDMETHODCALLTYPE GetTrustLevel(TrustLevel* level) override { return original->GetTrustLevel(level); }
    HRESULT STDMETHODCALLTYPE Copy(Imaging::ISoftwareBitmap* source, Imaging::ISoftwareBitmap** value) override { return original->Copy(source, value); }
    HRESULT STDMETHODCALLTYPE Convert(Imaging::ISoftwareBitmap* source, Imaging::BitmapPixelFormat format, Imaging::ISoftwareBitmap** value) override { return original->Convert(source, format, value); }
    HRESULT STDMETHODCALLTYPE ConvertWithAlpha(Imaging::ISoftwareBitmap* source, Imaging::BitmapPixelFormat format, Imaging::BitmapAlphaMode alpha, Imaging::ISoftwareBitmap** value) override { return original->ConvertWithAlpha(source, format, alpha, value); }
    HRESULT STDMETHODCALLTYPE CreateCopyFromBuffer(Streams::IBuffer* source, Imaging::BitmapPixelFormat format, INT32 width, INT32 height, Imaging::ISoftwareBitmap** value) override { return original->CreateCopyFromBuffer(source, format, width, height, value); }
    HRESULT STDMETHODCALLTYPE CreateCopyWithAlphaFromBuffer(Streams::IBuffer* source, Imaging::BitmapPixelFormat format, INT32 width, INT32 height, Imaging::BitmapAlphaMode alpha, Imaging::ISoftwareBitmap** value) override { return original->CreateCopyWithAlphaFromBuffer(source, format, width, height, alpha, value); }
    HRESULT STDMETHODCALLTYPE CreateCopyFromSurfaceAsync(Direct3D::IDirect3DSurface* surface, Operation** value) override { return copy(surface, Imaging::BitmapAlphaMode_Straight, value); }
    HRESULT STDMETHODCALLTYPE CreateCopyWithAlphaFromSurfaceAsync(Direct3D::IDirect3DSurface* surface, Imaging::BitmapAlphaMode alpha, Operation** value) override { return copy(surface, alpha, value); }
};

extern "C" __declspec(dllexport) HRESULT WINAPI WgcRoGetActivationFactory(HSTRING name, REFIID id, void** output) noexcept {
    if (!output) return E_POINTER;
    *output = nullptr;
    const auto hr = RoGetActivationFactory(name, id, output);
    if (FAILED(hr)) return hr;
    UINT32 length = 0;
    const auto text = WindowsGetStringRawBuffer(name, &length);
    constexpr auto expected = L"Windows.Graphics.Imaging.SoftwareBitmap";
    if (id != __uuidof(Imaging::ISoftwareBitmapStatics) || length != wcslen(expected) || wmemcmp(text, expected, length) != 0) return hr;
    auto original = static_cast<Imaging::ISoftwareBitmapStatics*>(*output);
    auto replacement = new (std::nothrow) BitmapStatics(original);
    original->Release();
    *output = replacement;
    return replacement ? S_OK : E_OUTOFMEMORY;
}
