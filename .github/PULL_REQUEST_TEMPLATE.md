<!--
The title takes the form of a commit subject, because the merge uses it:
`type(scope): summary`, in the imperative, under 60 characters. The scope is the
layer or the module: `fix(sys/cmd): ...`.
-->

## What changed

<!--
Open with a paragraph only where a reader would otherwise ask why this is one
pull request. Then one bullet per change, naming the module and the function it
touches.
-->

-

## How it was checked

<!--
The output of `make check`, and for a module of the api layer the system it ran
on. Name anything you could not check here and say why, so a reviewer knows what
CI is carrying.
-->

## Checklist

- [ ] `make check` passes.
- [ ] A line under `Unreleased` in `CHANGELOG.md` for a change a user would notice.
- [ ] Every new function has a docblock, and its tests read as `function: case -> expectation`.
