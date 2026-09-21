#pragma once
#include <robuffer.h>
#include <cstring>
#include <limits>

// 从 WGC 已授权提供的 BGRA 纹理同步复制像素，不调用异步表面转换。
inline HRESULT copy_wgc_surface(
    ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface* surface,
    ABI::Windows::Graphics::Imaging::BitmapAlphaMode alpha,
    ABI::Windows::Graphics::Imaging::ISoftwareBitmap** output) noexcept {
    using Microsoft::WRL::ComPtr;
    namespace Imaging = ABI::Windows::Graphics::Imaging;
    namespace Streams = ABI::Windows::Storage::Streams;
    if (!output) return E_POINTER;
    *output = nullptr;
    if (!surface) return E_INVALIDARG;
    HRESULT hr;
    ComPtr<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> access;
    if (FAILED(hr = surface->QueryInterface(IID_PPV_ARGS(&access)))) return hr;
    ComPtr<ID3D11Texture2D> texture;
    if (FAILED(hr = access->GetInterface(IID_PPV_ARGS(&texture)))) return hr;
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM || desc.ArraySize != 1 || desc.SampleDesc.Count != 1) return E_NOTIMPL;
    const UINT64 byte_count = UINT64(desc.Width) * desc.Height * 4;
    if (!desc.Width || !desc.Height || byte_count > std::numeric_limits<UINT32>::max()) return E_INVALIDARG;
    ComPtr<ID3D11Device> device;
    texture->GetDevice(&device);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(hr = device->CreateTexture2D(&desc, nullptr, &staging))) return hr;

    HSTRING class_name = nullptr;
    constexpr auto buffer_name = L"Windows.Storage.Streams.Buffer";
    if (FAILED(hr = WindowsCreateString(buffer_name, static_cast<UINT32>(wcslen(buffer_name)), &class_name))) return hr;
    ComPtr<Streams::IBufferFactory> buffer_factory;
    hr = RoGetActivationFactory(class_name, IID_PPV_ARGS(&buffer_factory));
    WindowsDeleteString(class_name);
    if (FAILED(hr)) return hr;
    ComPtr<Streams::IBuffer> buffer;
    if (FAILED(hr = buffer_factory->Create(static_cast<UINT32>(byte_count), &buffer))) return hr;
    if (FAILED(hr = buffer->put_Length(static_cast<UINT32>(byte_count)))) return hr;
    ComPtr<Windows::Storage::Streams::IBufferByteAccess> bytes;
    if (FAILED(hr = buffer.As(&bytes))) return hr;
    byte* pixels = nullptr;
    if (FAILED(hr = bytes->Buffer(&pixels))) return hr;
    ComPtr<ID3D11DeviceContext> context;
    device->GetImmediateContext(&context);
    context->CopyResource(staging.Get(), texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(hr = context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return hr;
    const auto row_bytes = static_cast<size_t>(desc.Width) * 4;
    for (UINT y = 0; y < desc.Height; ++y) {
        std::memcpy(pixels + y * row_bytes, static_cast<const byte*>(mapped.pData) + y * mapped.RowPitch, row_bytes);
    }
    context->Unmap(staging.Get(), 0);

    constexpr auto bitmap_name = L"Windows.Graphics.Imaging.SoftwareBitmap";
    if (FAILED(hr = WindowsCreateString(bitmap_name, static_cast<UINT32>(wcslen(bitmap_name)), &class_name))) return hr;
    ComPtr<Imaging::ISoftwareBitmapStatics> bitmap_factory;
    hr = RoGetActivationFactory(class_name, IID_PPV_ARGS(&bitmap_factory));
    WindowsDeleteString(class_name);
    if (FAILED(hr)) return hr;
    return bitmap_factory->CreateCopyWithAlphaFromBuffer(buffer.Get(), Imaging::BitmapPixelFormat_Bgra8,
        static_cast<INT32>(desc.Width), static_cast<INT32>(desc.Height), alpha, output);
}
