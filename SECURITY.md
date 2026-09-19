# Security policy

## Supported versions

The latest tagged version is supported.

## Reporting a vulnerability

Report a vulnerability through GitHub's private vulnerability reporting on this repository,
under its Security tab. Do not open a public issue. We acknowledge a report within three
working days and publish a fix before any disclosure.

## Input handling

The api layer changes the system it runs on: disks, users, packages, services, firewall
rules. A module takes its input as arguments and passes it on to commands as arguments, and
never through `eval`. Module names given to the importer are checked before a file is
sourced, so a name cannot leave the library directory. Configuration under `/etc/stealth`
is read as `key=value` lines, not sourced. The tests of a module run with no network and no
capabilities, and mock the commands it calls.
