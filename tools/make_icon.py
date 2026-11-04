"""Genera AppIcon.icns per DualSense Battery (griglia icone macOS: 824px su 1024).

Non serve per compilare: l'icona è già nel repository. Serve solo per modificarla.
"""
import io
import struct
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 2                      # supersampling per bordi morbidi
N = 1024 * S


def p(v):
    return int(round(v * S))


def box(x0, y0, x1, y1):
    return [p(x0), p(y0), p(x1), p(y1)]


def master() -> Image.Image:
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # Ombra sotto la piastrella
    shadow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(box(100, 112, 924, 936), radius=p(185), fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(p(14)))
    canvas.paste((0, 0, 0, 255), (0, 0), shadow)

    # Sfondo: gradiente verticale indaco → blu notte
    top, bottom = (66, 84, 214), (16, 20, 68)
    grad = Image.new("RGBA", (1, N))
    for y in range(N):
        t = y / (N - 1)
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    grad = grad.resize((N, N))
    tile = Image.new("L", (N, N), 0)
    ImageDraw.Draw(tile).rounded_rectangle(box(100, 100, 924, 924), radius=p(185), fill=255)
    canvas.paste(grad, (0, 0), tile)

    # Leggera luce in alto
    glow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(glow).ellipse(box(180, -260, 844, 420), fill=46)
    glow = glow.filter(ImageFilter.GaussianBlur(p(60)))
    glow = Image.composite(glow, Image.new("L", (N, N), 0), tile)
    canvas.paste((255, 255, 255, 255), (0, 0), glow)

    white = (246, 248, 255, 255)
    d = ImageDraw.Draw(canvas)

    # Batteria
    d.rounded_rectangle(box(392, 262, 612, 352), radius=p(28), outline=white, width=p(16))
    d.rounded_rectangle(box(620, 286, 640, 328), radius=p(8), fill=white)
    inner_left, inner_right = 418, 586
    level = 0.72
    d.rounded_rectangle(box(inner_left, 288, inner_left + (inner_right - inner_left) * level, 326),
                        radius=p(12), fill=(74, 222, 128, 255))

    # Controller stilizzato: corpo + impugnature, con tasti "scavati"
    pad = Image.new("L", (N, N), 0)
    m = ImageDraw.Draw(pad)
    m.rounded_rectangle(box(262, 445, 762, 655), radius=p(105), fill=255)
    for cx in (322, 702):
        m.ellipse(box(cx - 100, 575, cx + 100, 775), fill=255)
    # croce direzionale
    m.rounded_rectangle(box(305, 522, 415, 558), radius=p(10), fill=0)
    m.rounded_rectangle(box(342, 485, 378, 595), radius=p(10), fill=0)
    # quattro tasti
    for bx, by in ((664, 498), (706, 540), (664, 582), (622, 540)):
        m.ellipse(box(bx - 19, by - 19, bx + 19, by + 19), fill=0)
    # levette
    for sx in (442, 582):
        m.ellipse(box(sx - 30, 590, sx + 30, 650), fill=0)
    canvas.paste(white, (0, 0), pad)

    return canvas


def png(img: Image.Image, size: int) -> bytes:
    out = io.BytesIO()
    img.resize((size, size), Image.LANCZOS).save(out, format="PNG", optimize=True)
    return out.getvalue()


def write_icns(img: Image.Image, path: str) -> None:
    entries = [
        (b"icp4", 16), (b"icp5", 32), (b"icp6", 64),
        (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
        (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
    ]
    chunks = b"".join(t + struct.pack(">I", len(data) + 8) + data
                      for t, data in ((t, png(img, s)) for t, s in entries))
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


if __name__ == "__main__":
    # Uso: python3 tools/make_icon.py [AppIcon.icns] [anteprima.png]   (richiede Pillow)
    icns_path = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"
    art = master()
    write_icns(art, icns_path)
    if len(sys.argv) > 2:
        art.resize((512, 512), Image.LANCZOS).save(sys.argv[2])
    print(f"Creata {icns_path}")
