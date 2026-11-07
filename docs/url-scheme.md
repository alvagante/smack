# URL navigation

`smack://` opens Summary. Resource pages use `cpu`, `memory`, `network`, `disk`, `storage`, `battery`
and `thermal`. Other hosts: `apps`, `ports`, `devservers`, `docker`, `homebrew`, `dev`, `projects`, `home`, `agents`, `installed`,
`startup`, `security`, `baseline`, `timeline`, `history`, `insights`, `settings`, `system`.

Specific routes: `smack://app/<bundle-id>`, `smack://process/<pid>`, `smack://port/<port>`,
`smack://settings/alerts`. Timeline accepts `since=1h`, comma-separated `kind`, and `q` search.
Only Timeline accepts query parameters. Unknown/malformed routes fall back to Summary.

Links navigate and pin the panel. They never run commands or change collection, alert rules or startup
items. Missing processes show Applications with a banner.
