# getassay.dev

Source for [getassay.dev](https://getassay.dev), the landing page and installer for the Assay CLI.

## Deployment

Hosted on **Cloudflare Pages**.

1.  Connect this repo to Cloudflare Pages.
2.  Set **Build output directory** to `/` (Project Root).
3.  Deploy.

## Installer provenance

`install.sh` is copied from the immutable Assay source commit recorded in
`install.provenance.json`. Pull requests and pushes to `main` run:

```bash
bash scripts/test-installer-provenance-contract.sh
bash scripts/check-installer-provenance.sh
```

The first command exercises the fail-closed and offline boundary without using
the network. The second checks the committed installer and, when reachable, the
immutable source.

`.github/workflows/installer-live-drift.yml` is the authoritative deployment
signal. It runs daily and can be dispatched manually. Its `--verify-live` mode
also checks `https://getassay.dev/install.sh` and reports the site commit, pinned
Assay commit, expected digest, and live digest. Exit `1` means invalid provenance
or drift. Exit `2` means the source or live endpoint was unavailable; that is a
failed operational proof, not a verified deployment.

Recovery does not bypass provenance: fix or revert the site branch through a PR,
wait for Cloudflare Pages to deploy `main`, then manually dispatch **Installer
live drift**. The required **Installer provenance contract** protects source and
pin changes before merge; Cloudflare Pages reports deployment completion; only
the live-drift workflow verifies the bytes served by the production domain.

## Files

-   `index.html`: The landing page.
-   `install.sh`: The installer script (served at /install.sh).
-   `_headers`: Security headers config.
