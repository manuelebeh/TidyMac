# Security policy

TidyMac removes files and can ask for your administrator password, so a flaw in it can cost someone their data. Reports are welcome and taken seriously.

## Supported versions

Only the latest release gets fixes. TidyMac has no automatic updates: look at [the releases page](https://github.com/manuelebeh/TidyMac/releases) for the newest version.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use [GitHub's private report form](https://github.com/manuelebeh/TidyMac/security/advisories/new) (Security › Report a vulnerability). Only the maintainers see it.

Include:

- the TidyMac version and your macOS version,
- what an attacker needs (a local app, a crafted file or folder name, a `tidymac://` link, a malicious page) and what they get,
- steps to reproduce, or a proof of concept that does not harm anything.

TidyMac is maintained by one person, so there is no guaranteed timeline. The aim is to answer within a week and to have a fix or a plan within a month for a confirmed flaw. A reporter who wants credit is named in the release notes.

## What counts

Things we want to hear about:

- a way to make TidyMac delete or move something it should refuse, outside the home folder or in a protected folder (see `RemovalGuard`),
- a way to run a command, or reach root, other than through the administrator prompt for what the user reviewed,
- a path, file name or link that breaks out of a quote in a command or an AppleScript,
- something leaving the Mac that the readme says does not.

Not security flaws: a scan that finds too much or too little, or a wrong size. Report those as ordinary issues.

## How TidyMac limits the damage

The safety rules are in [CONTRIBUTING.md](CONTRIBUTING.md#safety-rules) and the readme. In short: everything goes through `Executor`, files go to the Trash, permanent removals outside the home folder are limited to a fixed list, commands are programs with arguments, and there is no privileged helper.
