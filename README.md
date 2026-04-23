# ci
github actions &amp; workflows


## How to use golang-ci-v2

In your project, you need to use the new golang-ci-v2 file

```yaml
jobs:
  ci:
    uses: your-org/your-repo/.github/workflows/golang-ci-v2.yml@main
    with:
      go-version: '~1.22'
      enable_integration: false            # ← disables the integration shard
      integration_packages: "./it/..."     # optional override
    secrets: inherit
```

By default, the integration shard is enabled. You can disable it by setting `enable_integration` to `false`.
You can also override the integration packages by setting `integration_packages` to your desired value.
