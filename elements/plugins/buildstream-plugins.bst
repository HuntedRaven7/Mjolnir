kind: junction

sources:
- kind: git_repo
  url: github:apache/buildstream-plugins.git
  track: '*.*.*'
  exclude:
  - '*dev*'
  ref: 2.8.0-0-g827d065e9db4ae66b0c90a5151edccd6951f37e9
