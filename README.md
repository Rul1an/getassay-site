# getassay.dev

Landing page and install script for Assay.

## Structure

```
public/
├── index.html      # Landing page
└── install.sh      # Install script
```

## Deploy to Cloudflare Pages

### Option 1: Via Dashboard (Easiest)

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/) → Pages
2. Create a project → Connect to Git
3. Select your `getassay.dev` repository
4. Configure build:
   - **Build command:** (leave empty)
   - **Build output directory:** `public`
5. Deploy

### Option 2: Via Wrangler CLI

```bash
# Install wrangler
npm install -g wrangler

# Login
wrangler login

# Deploy
wrangler pages deploy public --project-name=getassay-dev
```

## Custom Domain

After deploying:

1. Go to your Pages project → Custom domains
2. Add `getassay.dev`
3. Update your domain's nameservers to Cloudflare (if not already)
4. Or add a CNAME record pointing to `getassay-dev.pages.dev`

## Testing Locally

```bash
# Simple HTTP server
cd public
python3 -m http.server 8080

# Open http://localhost:8080
```

## Install Script

The install script:
- Detects OS (Linux, macOS, Windows via Git Bash)
- Detects architecture (x86_64, aarch64)
- Downloads from GitHub Releases
- Verifies SHA256 checksum
- Installs to `~/.local/bin`

### Customization via Environment Variables

```bash
# Specific version
curl -fsSL https://getassay.dev/install.sh | ASSAY_VERSION=v1.3.0 sh

# Custom install directory
curl -fsSL https://getassay.dev/install.sh | ASSAY_INSTALL_DIR=/usr/local/bin sudo sh
```

## URLs After Deploy

| URL | Content |
|-----|---------|
| `https://getassay.dev` | Landing page |
| `https://getassay.dev/install.sh` | Install script |
