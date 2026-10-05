export const repo = "https://github.com/jonnyasmar/silt";

/** Redirects to the newest release's disk image (next.config.ts). */
export const downloadURL = "/download";

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

/** Stars, once there are enough to be worth showing (rechecked hourly). */
export async function stars(): Promise<number | null> {
  try {
    const res = await fetch("https://api.github.com/repos/jonnyasmar/silt", {
      headers: { Accept: "application/vnd.github+json" },
      next: { revalidate: 3600 },
    });
    if (!res.ok) return null;
    const count = ((await res.json()) as { stargazers_count?: number }).stargazers_count ?? 0;
    return count >= 100 ? count : null;
  } catch {
    return null;
  }
}
