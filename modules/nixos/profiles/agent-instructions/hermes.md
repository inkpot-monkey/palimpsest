## Fetching a web page

`scrapling` is on your PATH. It fetches a page and gives you back markdown
rather than raw HTML, which is almost always what you want:

```sh
scrapling extract get <url> out.md      # plain HTTP
scrapling extract fetch <url> out.md    # through a real browser, for a page that needs JS
```

The same library is importable from `python3` (`from scrapling.fetchers import Fetcher, StealthyFetcher`) when you need the parsed tree rather than a file.

Do not reach for `nix shell nixpkgs#scrapling` — it is not in nixpkgs. It is
declared for you in the fleet configuration, which is why it is already there.

The `scrapling` skill's own Installation section says to `pip install "scrapling[all]"` and then run `scrapling install`. Ignore both on this host:
the package is already installed with every extra, and the browser `scrapling install` would download is already provided through `PLAYWRIGHT_BROWSERS_PATH`.
Running them wastes a turn and installs nothing that works.

## On-demand tool installs are off

Your own package manager (`hermes pm`) cannot install tools on this host, and
its tool store is cleared before every start. This is deliberate: what it
downloads are generic-linux binaries, and NixOS cannot execute those — a
CPython it installed once silently shadowed the real interpreter with a binary
that exits 127.

So a tool you need is either already here, reachable through `nix shell` (above),
or worth asking to have declared. Nothing you install into your state directory
will survive.
