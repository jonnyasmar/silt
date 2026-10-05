export const repo = "https://github.com/jonnyasmar/silt";

/** Every release carries the disk image under this fixed name as well. */
export const downloadURL = `${repo}/releases/latest/download/Silt.dmg`;

export type Release = { version: string; url: string; date: string };

/** The newest published release, rechecked every ten minutes; null before
 * the first one exists (or if GitHub can't be reached). */
export async function latestRelease(): Promise<Release | null> {
  try {
    const res = await fetch("https://api.github.com/repos/jonnyasmar/silt/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
      next: { revalidate: 600 },
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { tag_name?: string; html_url?: string; published_at?: string };
    if (!json.tag_name || !json.html_url) return null;
    return { version: json.tag_name.replace(/^v/, ""), url: json.html_url, date: json.published_at ?? "" };
  } catch {
    return null;
  }
}
