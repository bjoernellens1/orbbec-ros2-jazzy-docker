# Create and push the public GitHub repository

The ChatGPT GitHub connector can write to existing repositories, but it does not currently expose a create-repository action. Use this once locally:

```bash
cd orbbec-ros2-jazzy-docker
git init
git add .
git commit -m "Initial ROS 2 Jazzy Orbbec Docker setup"

gh repo create bjoernellens1/orbbec-ros2-jazzy-docker \
  --public \
  --source=. \
  --remote=origin \
  --push \
  --description "Containerized OrbbecSDK ROS 2 Jazzy publisher for Orbbec Femto Bolt"
```

After pushing, open GitHub Actions and check that the `Build container` workflow succeeds.
