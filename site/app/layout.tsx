import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono, Instrument_Serif } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });
const instrumentSerif = Instrument_Serif({
  variable: "--font-instrument-serif",
  subsets: ["latin"],
  weight: "400",
  style: ["normal", "italic"],
});

const description =
  "Silt is a fast, live disk-space explorer for macOS. It scans in seconds, stays current as files change, and helps you clear space without deleting the wrong thing. Free and open source.";

export const metadata: Metadata = {
  metadataBase: new URL("https://usesilt.app"),
  title: "Silt: see what’s filling your Mac",
  description,
  applicationName: "Silt",
  openGraph: {
    title: "Silt: see what’s filling your Mac",
    description,
    url: "https://usesilt.app",
    siteName: "Silt",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Silt: see what’s filling your Mac",
    description,
    creator: "@jonnygravity",
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#fbf6ec" },
    { media: "(prefers-color-scheme: dark)", color: "#15100a" },
  ],
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} ${instrumentSerif.variable} antialiased`}
    >
      <body className="min-h-dvh font-sans">{children}</body>
    </html>
  );
}
