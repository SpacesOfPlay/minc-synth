// shot.mc: saves the frame just rendered to a PNG, for checking the UI
// without a visible window. Direct3D 11 only; elsewhere it reports false.
//
// Call it with the frame's swapchain after sg_commit, before the frame
// callback returns: the back buffer holds the frame until it is presented.

import sokol_all;
import png;
import str;

when os(windows) {
    private {
        const i32 D3D11_USAGE_STAGING = 3;
        const u32 D3D11_CPU_ACCESS_READ = 0x20000;
        const i32 D3D11_MAP_READ = 1;
        const i32 DXGI_FORMAT_R8G8B8A8_UNORM = 28;
        const i32 DXGI_FORMAT_B8G8R8A8_UNORM = 87;

        // Only the vtable slots used here; the rest are padding.
        struct ViewVtbl {
            void*[2] _pad0;
            fn(void*): u32 Release;
            void*[4] _pad3;
            fn(void*, void**): void GetResource;
        }
        struct View { ViewVtbl* lpVtbl; }

        struct Tex2DVtbl {
            void*[2] _pad0;
            fn(void*): u32 Release;
            void*[7] _pad3;
            fn(void*, D3D11_TEXTURE2D_DESC*): void GetDesc;
        }
        struct Tex2D { Tex2DVtbl* lpVtbl; }

        struct DeviceVtbl {
            void*[5] _pad0;
            fn(void*, D3D11_TEXTURE2D_DESC*, void*, void**): i32 CreateTexture2D;
        }
        struct Device { DeviceVtbl* lpVtbl; }

        struct ContextVtbl {
            void*[14] _pad0;
            fn(void*, void*, u32, i32, u32, D3D11_MAPPED_SUBRESOURCE*): i32 Map;
            fn(void*, void*, u32): void Unmap;
            void*[31] _pad16;
            fn(void*, void*, void*): void CopyResource;
        }
        struct Context { ContextVtbl* lpVtbl; }
    }

    bool shot_save(str path, sg_swapchain sc) {
        View* view = cast(View*, sc.d3d11.resolve_view);
        if view == null { view = cast(View*, sc.d3d11.render_view); }
        Device* dev = cast(Device*, sg_d3d11_device());
        Context* ctx = cast(Context*, sg_d3d11_device_context());
        if view == null || dev == null || ctx == null { return false; }

        void* res = null;
        view.lpVtbl.GetResource(view, &res);
        if res == null { return false; }
        Tex2D* back = cast(Tex2D*, res);
        defer back.lpVtbl.Release(back);
        D3D11_TEXTURE2D_DESC desc;
        back.lpVtbl.GetDesc(back, &desc);
        if desc.SampleDesc.Count != 1 { return false; }
        bool bgra = desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM;
        if !bgra && desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM { return false; }

        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        desc.MiscFlags = 0;
        void* staging_ptr = null;
        if dev.lpVtbl.CreateTexture2D(dev, &desc, null, &staging_ptr) < 0 || staging_ptr == null { return false; }
        Tex2D* staging = cast(Tex2D*, staging_ptr);
        defer staging.lpVtbl.Release(staging);
        ctx.lpVtbl.CopyResource(ctx, staging, back);

        D3D11_MAPPED_SUBRESOURCE m;
        if ctx.lpVtbl.Map(ctx, staging, 0, D3D11_MAP_READ, 0, &m) < 0 { return false; }
        i32 w = cast(i32, desc.Width);
        i32 h = cast(i32, desc.Height);
        u8* px = alloc<u8>(cast(i64, w) * h * 4);
        defer free(px);
        u8* src = cast(u8*, m.pData);
        for i32 y = 0; y < h; y++ {
            u8* row = src + cast(i64, y) * m.RowPitch;
            u8* dst = px + cast(i64, y) * w * 4;
            for i32 x = 0; x < w; x++ {
                u8 r = row[x * 4];
                u8 b = row[x * 4 + 2];
                if bgra {
                    r = row[x * 4 + 2];
                    b = row[x * 4];
                }
                dst[x * 4] = r;
                dst[x * 4 + 1] = row[x * 4 + 1];
                dst[x * 4 + 2] = b;
                dst[x * 4 + 3] = 255;
            }
        }
        ctx.lpVtbl.Unmap(ctx, staging, 0);
        return png_save(path, px, w, h) == 0;
    }
} else {
    bool shot_save(str path, sg_swapchain sc) { return false; }
}
