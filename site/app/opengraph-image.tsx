import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";

export const alt = "Silt: see what’s filling your Mac";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function OpenGraphImage() {
  const icon = await readFile(join(process.cwd(), "public/silt-icon.png"));
  const src = `data:image/png;base64,${icon.toString("base64")}`;
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          padding: "0 90px",
          gap: 64,
          background: "linear-gradient(180deg, #fbf6ec 0%, #f3e6cb 100%)",
          color: "#211709",
        }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={src} width={360} height={360} alt="" />
        <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
          <div style={{ fontSize: 96, fontWeight: 700, letterSpacing: -3 }}>Silt</div>
          <div style={{ fontSize: 44, lineHeight: 1.2, maxWidth: 620 }}>See what’s filling your Mac. As it fills.</div>
          <div style={{ fontSize: 28, color: "#6e5a43" }}>Free and open source · usesilt.app</div>
        </div>
      </div>
    ),
    size,
  );
}
