import Image from "next/image";
import {
  Download,
  FolderTree,
  ShieldCheck,
  Files,
  Sparkles,
  TrendingUp,
  Scale,
  Gauge,
  Rabbit,
  Turtle,
  Pause,
  Flame,
  SlidersHorizontal,
  Undo2,
  Lock,
  HardDrive,
  CopyCheck,
  type LucideIcon,
} from "lucide-react";
import { Strata } from "./_components/strata";
import { downloadURL, latestRelease, repo } from "@/lib/release";

export default async function Home() {
  const release = await latestRelease();
  return (
    <>
      <Header />
      <main>
        <Hero version={release?.version} />
        <Strata className="h-16 md:h-24" />
        <Fast />
        <Features />
        <Speed />
        <Safety />
        <OpenSource version={release?.version} />
      </main>
      <Footer />
    </>
  );
}

function GitHubMark({ className = "size-4" }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

function DownloadButton({ size = "lg" }: { size?: "sm" | "lg" }) {
  const big = size === "lg";
  return (
    <a
      href={downloadURL}
      className={`inline-flex items-center gap-2 rounded-full bg-ochre font-medium text-on-ochre shadow-[0_1px_0_rgba(255,255,255,0.35)_inset,0_6px_20px_-8px_rgba(154,95,23,0.6)] transition hover:brightness-105 active:brightness-95 ${
        big ? "px-6 py-3 text-base" : "px-4 py-1.5 text-sm"
      }`}
    >
      <Download className={big ? "size-5" : "size-4"} strokeWidth={2.25} aria-hidden="true" />
      Download for Mac
    </a>
  );
}

function Header() {
  return (
    <header className="sticky top-0 z-20 border-b border-line/60 bg-paper/80 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-5">
        <a href="#" className="flex items-center gap-2.5" aria-label="Silt home">
          <Image src="/silt-icon.png" alt="" width={28} height={28} className="size-7" priority />
          <span className="font-display text-2xl leading-none tracking-tight">Silt</span>
        </a>
        <nav className="flex items-center gap-1 text-sm text-muted sm:gap-2">
          <a href="#features" className="hidden rounded-full px-3 py-1.5 hover:text-ink sm:block">
            Features
          </a>
          <a href="#speed" className="hidden rounded-full px-3 py-1.5 hover:text-ink sm:block">
            Speed
          </a>
          <a href="#safety" className="hidden rounded-full px-3 py-1.5 hover:text-ink md:block">
            Safety
          </a>
          <a
            href={repo}
            className="flex items-center gap-1.5 rounded-full px-3 py-1.5 hover:text-ink"
            aria-label="Silt on GitHub"
          >
            <GitHubMark />
            <span className="hidden sm:inline">GitHub</span>
          </a>
          <DownloadButton size="sm" />
        </nav>
      </div>
    </header>
  );
}

function Hero({ version }: { version?: string }) {
  return (
    <section className="relative overflow-hidden">
      <div className="mx-auto grid max-w-6xl items-center gap-12 px-5 pt-16 pb-10 md:grid-cols-[1.15fr_0.85fr] md:pt-24">
        <div>
          <p className="mb-5 text-sm font-medium tracking-wide text-ochre-deep">
            Free and open source · macOS 15 or later
          </p>
          <h1 className="font-display text-6xl leading-[0.95] tracking-tight text-balance sm:text-7xl">
            See what’s filling your Mac.{" "}
            <span className="text-muted italic">As it fills.</span>
          </h1>
          <p className="mt-6 max-w-xl text-lg leading-relaxed text-muted">
            Silt scans your disk in seconds, then keeps a live, drillable tree of every folder as files
            come and go. When you’re ready to clear space, it tells you what’s safe and refuses to
            delete what isn’t.
          </p>
          <div className="mt-9 flex flex-wrap items-center gap-4">
            <DownloadButton />
            <a
              href={repo}
              className="inline-flex items-center gap-2 rounded-full border border-line px-5 py-3 text-base font-medium hover:border-ochre/60"
            >
              <GitHubMark className="size-5" />
              View source
            </a>
          </div>
          <p className="mt-5 text-sm text-muted">
            {version ? `Version ${version} · ` : ""}Universal: Apple silicon and Intel · Notarized by Apple
          </p>
        </div>
        <div className="relative mx-auto w-full max-w-[22rem] md:max-w-none">
          <div
            className="absolute inset-[12%] rounded-full bg-ochre/25 blur-3xl"
            aria-hidden="true"
          />
          <Image
            src="/silt-icon.png"
            alt="The Silt app icon: layers of river sediment"
            width={1024}
            height={1024}
            priority
            className="relative w-full drop-shadow-[0_30px_40px_rgba(90,55,15,0.28)]"
          />
        </div>
      </div>
    </section>
  );
}

function SectionHeading({ eyebrow, title, children }: { eyebrow: string; title: string; children?: React.ReactNode }) {
  return (
    <div className="max-w-2xl">
      <p className="mb-3 text-sm font-medium tracking-wide text-ochre-deep">{eyebrow}</p>
      <h2 className="font-display text-4xl leading-tight tracking-tight text-balance sm:text-5xl">{title}</h2>
      {children && <p className="mt-4 text-lg leading-relaxed text-muted">{children}</p>}
    </div>
  );
}

function Fast() {
  const runs = [
    { label: "Silt", seconds: 8.9, tone: "bg-ochre" },
    { label: "du -sk", seconds: 71, tone: "bg-muted/40" },
  ];
  const max = 71;
  return (
    <section className="bg-sand/60">
      <div className="mx-auto max-w-6xl px-5 py-20">
        <SectionHeading eyebrow="Fast" title="Fast enough to leave open.">
          A whole developer folder, 1.3 million items, in under nine seconds. Then Silt stays current by
          re-reading only the folders that change.
        </SectionHeading>
        <div className="mt-10 space-y-4">
          {runs.map((r) => (
            <div key={r.label} className="grid grid-cols-[5.5rem_1fr] items-center gap-4">
              <span className="font-mono text-sm text-muted">{r.label}</span>
              <div className="flex items-center gap-3">
                {/* Scaled to the row minus room for its label, so the label sits at the bar's end. */}
                <div
                  className={`h-3.5 shrink-0 rounded-full ${r.tone}`}
                  style={{ width: `calc((100% - 4.5rem) * ${r.seconds / max})`, minWidth: "1.5rem" }}
                />
                <span className="font-mono text-sm whitespace-nowrap tabular-nums">{r.seconds} s</span>
              </div>
            </div>
          ))}
          <p className="pt-1 text-xs text-muted">
            Scanning ~/dev (1.3M items) on an M3 Max with other work running.
          </p>
        </div>
        <dl className="mt-14 grid gap-8 sm:grid-cols-3">
          {[
            ["~55 MB", "for 1.2 million items, held in a flat, chunked tree"],
            ["0.03%", "of a core while a quiet folder sits open"],
            ["Instant", "relaunch: the last scan loads straight back, then catches up"],
          ].map(([value, label]) => (
            <div key={value} className="border-t border-line pt-4">
              <dt className="font-display text-4xl tracking-tight">{value}</dt>
              <dd className="mt-1 text-sm leading-relaxed text-muted">{label}</dd>
            </div>
          ))}
        </dl>
      </div>
    </section>
  );
}

function Card({ icon: Icon, title, children }: { icon: LucideIcon; title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-2xl border border-line bg-surface p-6">
      <Icon className="size-6 text-ochre" strokeWidth={1.75} aria-hidden="true" />
      <h3 className="mt-4 text-lg font-semibold tracking-tight">{title}</h3>
      <p className="mt-2 text-[0.95rem] leading-relaxed text-muted">{children}</p>
    </div>
  );
}

function Features() {
  return (
    <section id="features" className="scroll-mt-16">
      <div className="mx-auto max-w-6xl px-5 py-20">
        <SectionHeading eyebrow="Features" title="Everything you need to get space back, and nothing you don’t." />
        <div className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          <Card icon={FolderTree} title="A live, drillable tree">
            In the spirit of WinDirStat: every folder’s size, sorted, filling in while it scans and staying
            current as files change. Space for Quick Look, ⌘R to show in Finder.
          </Card>
          <Card icon={Sparkles} title="Reclaim">
            Caches, build output (node_modules, Rust targets, DerivedData), installers and model weights,
            grouped and sized, with build output from projects you haven’t touched in months at the top.
          </Card>
          <Card icon={Files} title="Duplicates">
            Files with identical contents, compared by size, a sampled hash, then a full SHA-256. APFS clones
            already share their blocks, so they aren’t counted as waste.
          </Card>
          <Card icon={TrendingUp} title="What changed">
            “+2.8 GB since yesterday.” Silt compares against the last scan and shows the folders that grew or
            shrank most.
          </Card>
          <Card icon={Scale} title="Sizes, precisely">
            Bytes on disk, counted once: hard links and clones are split between the files sharing them, and
            the space the volume reports but no scan can see is broken down too.
          </Card>
          <Card icon={CopyCheck} title="A cleanup basket">
            Mark anything as you go, then review it in one place, with a safety verdict on every item. Trash
            with Undo by default; deleting right away asks first.
          </Card>
        </div>
      </div>
    </section>
  );
}

function Speed() {
  const modes: [LucideIcon, string, string][] = [
    [Gauge, "Automatic", "Scans you start run flat out. Keeping up with changes runs in the background, and everything eases off on battery, in Low Power Mode or when the Mac runs hot."],
    [Rabbit, "Fast", "Everything at full priority, catching up included. Close a few apps and get the answer now."],
    [Turtle, "Gentle", "Low priority, on the efficiency cores, with slower disk access. Takes longer; you won’t notice it."],
    [Pause, "Paused", "Silt does nothing on its own, but remembers what changed and catches up when you resume."],
  ];
  return (
    <section id="speed" className="scroll-mt-16 bg-sand/60">
      <div className="mx-auto max-w-6xl px-5 py-20">
        <SectionHeading eyebrow="Your pace" title="You decide how hard it works.">
          Most disk tools scan once and quit. Silt stays open and keeps watching, so it lets you choose how
          much of your Mac that’s worth.
        </SectionHeading>
        <div className="mt-12 grid gap-4 sm:grid-cols-2">
          {modes.map(([Icon, name, text]) => (
            <div key={name} className="flex gap-4 rounded-2xl border border-line bg-surface p-5">
              <Icon className="mt-0.5 size-5 shrink-0 text-ochre" strokeWidth={1.75} aria-hidden="true" />
              <div>
                <h3 className="font-semibold tracking-tight">{name}</h3>
                <p className="mt-1 text-[0.95rem] leading-relaxed text-muted">{text}</p>
              </div>
            </div>
          ))}
        </div>
        <div className="mt-10 grid gap-8 md:grid-cols-2">
          <div className="flex gap-4">
            <Flame className="mt-1 size-5 shrink-0 text-ochre" strokeWidth={1.75} aria-hidden="true" />
            <div>
              <h3 className="font-semibold tracking-tight">Busy folders slow down by themselves</h3>
              <p className="mt-1 leading-relaxed text-muted">
                A folder that never stops changing (agent logs, a build in progress) is updated less and less
                often, down to every 30 seconds. One you have open still updates every couple of seconds.
              </p>
            </div>
          </div>
          <div className="flex gap-4">
            <SlidersHorizontal className="mt-1 size-5 shrink-0 text-ochre" strokeWidth={1.75} aria-hidden="true" />
            <div>
              <h3 className="font-semibold tracking-tight">Rules for any folder</h3>
              <p className="mt-1 leading-relaxed text-muted">
                Right-click a folder to keep it live, update it slowly, pause it until you open it, or leave it
                out of the scan entirely.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function Safety() {
  const points: [LucideIcon, string][] = [
    [Undo2, "Moves to the Trash by default, with Undo. Deleting right away always asks first."],
    [CopyCheck, "Never removes the last copy of a duplicate, and leaves a copy alone if it changed since the search."],
    [ShieldCheck, "A mark is tied to the exact file it was made on. If that file is replaced, the mark is dropped."],
    [HardDrive, "Won’t delete a volume mounted inside your scan, or system and home folders."],
    [Lock, "Only calls build output “safe” inside your own projects, never inside an app or an installed tool."],
    [Sparkles, "Tells you when a folder you marked has grown since, before you clear it."],
  ];
  return (
    <section id="safety" className="scroll-mt-16">
      <div className="mx-auto max-w-6xl px-5 py-20">
        <SectionHeading eyebrow="Safety" title="Built not to delete the wrong thing.">
          A tool that frees space can also lose your work. Every destructive path in Silt checks again before
          it acts.
        </SectionHeading>
        <ul className="mt-12 grid gap-x-10 gap-y-6 md:grid-cols-2">
          {points.map(([Icon, text]) => (
            <li key={text} className="flex gap-4">
              <Icon className="mt-0.5 size-5 shrink-0 text-ochre" strokeWidth={1.75} aria-hidden="true" />
              <span className="leading-relaxed">{text}</span>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

function OpenSource({ version }: { version?: string }) {
  return (
    <section className="bg-sand/60">
      <div className="mx-auto flex max-w-6xl flex-col items-center px-5 py-20 text-center">
        <Image src="/silt-icon.png" alt="" width={96} height={96} className="size-24" />
        <h2 className="mt-6 font-display text-4xl tracking-tight text-balance sm:text-5xl">
          Free, open source, and yours to keep.
        </h2>
        <p className="mt-4 max-w-xl text-lg leading-relaxed text-muted">
          MIT licensed and built in the open. If Silt got you some space back, you can buy me a coffee.
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-4">
          <DownloadButton />
          <a href="https://www.buymeacoffee.com/jonnygravity" aria-label="Buy me a coffee">
            {/* Silt's own colours, kept in the repo (no live supporter count). */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/buy-me-a-coffee.svg" alt="Buy me a coffee" width={168} height={50} className="h-12 w-auto" />
          </a>
        </div>
        <p className="mt-5 text-sm text-muted">
          {version ? `Version ${version} · ` : ""}Requires macOS 15 or later
        </p>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="border-t border-line">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-5 py-8 text-sm text-muted sm:flex-row">
        <p>© 2026 Jonny Asmar · MIT License</p>
        <nav className="flex gap-5">
          <a href={repo} className="hover:text-ink">GitHub</a>
          <a href={`${repo}/releases`} className="hover:text-ink">Releases</a>
          <a href="https://www.buymeacoffee.com/jonnygravity" className="hover:text-ink">Buy me a coffee</a>
        </nav>
      </div>
    </footer>
  );
}
