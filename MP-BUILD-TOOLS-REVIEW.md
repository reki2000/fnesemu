# mp-build-tools extraction review

Prepared source for the new public repository `reki2000/mp-build-tools` is under [tools/mp-build-tools](tools/mp-build-tools). This review branch keeps the three existing application PRs and their successful CI revisions untouched.

The GitHub connector cannot create repositories. After repository creation, publish the files from `tools/mp-build-tools/`, replace every `REPLACE_WITH_PUBLISHED_SHA` in the consumer templates with the resulting reviewed commit SHA, and update the existing PRs. Remove the seven duplicated `.github/scripts/` helpers from each caller.

Consumer templates are under [examples](tools/mp-build-tools/examples). Their tests, trigger rules, full matrix, completion marker gating and serialized Pages publishing match the existing application workflows. Shared Action logic is provided by four Composite Actions.

Review CI validates the shared metadata and source policy and exercises composite version/configuration paths on Linux, macOS and Windows. Full consumer builds must run after the shared repository is published.
