## Unreleased

- Add `dactor_test` as a dev dependency. The 1.2.0 release moved the test
  toolkit out of this package but never declared it, so 9 of the 12 test files
  could not load from a clean checkout. Added a GitHub Actions workflow that
  runs `dart analyze` and the unit tests on every push and pull request.
- README: the testing section now points at the `dactor_test` package.

## 1.2.0

- Fix actor model correctness, supervision, and messaging issues
- Remove `test` from regular dependencies (was incorrectly listed as runtime dep)
- Extract test utilities into separate `dactor_test` package

## 1.1.0

- **Docs**: Added comprehensive documentation for testing actors, including `TestActorSystem`, `TestProbe`, and message tracing.

## 1.0.0

- Initial version.
