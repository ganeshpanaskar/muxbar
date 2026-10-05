# Security policy

Muxbar runs commands on your Mac and on SSH hosts you configure, so security reports are very welcome.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through
[GitHub Security Advisories](https://github.com/ganeshpanaskar/muxbar/security/advisories/new).
You'll get a reply within a week, and a fix and credit (if you want it) once it's confirmed.

## Scope

Of particular interest: shell quoting/injection in commands Muxbar builds (session names,
folders, conversation ids, agent commands), the local control socket, and anything that could
leak data off the machine. Muxbar itself never contacts any AI provider or other network service
besides SSH to your own hosts.

## Supported versions

Only the latest release on `main` gets fixes.
