import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  async redirects() {
    return [
      {
        // A link that never changes, to whatever the newest release is. Every
        // release carries the disk image under this fixed name.
        source: "/download",
        destination: "https://github.com/jonnyasmar/silt/releases/latest/download/Silt.dmg",
        permanent: false,
      },
    ];
  },
};

export default nextConfig;
