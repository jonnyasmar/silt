# usesilt.app

The website for [Silt](../README.md): Next.js (App Router), Tailwind CSS,
deployed by Vercel from `main` (this folder is the project's root directory).

```sh
pnpm install
pnpm dev     # http://localhost:3000
pnpm build   # NODE_ENV must be production (or unset) for next build
```

The download button links to `releases/latest/download/Silt.dmg`, which every
release carries (see `.github/workflows/release.yml`); the version shown comes
from GitHub's latest release, rechecked every ten minutes.
