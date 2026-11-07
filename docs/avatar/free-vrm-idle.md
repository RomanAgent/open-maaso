# Bundled VRM idle pose

The reviewed Pixiv VRM is unchanged. Its redistribution hash and license remain
beside `OpenMaaso.vrm`. This fix changes the generated Humanoid idle clip rather
than rewriting the model, skin weights or shared avatar runtime.

`MaasoDefaultAvatarSceneBuilder.EnsureOfflineController` captures the imported
model's `HumanPose` before animation. The idle includes its complete 89 body,
limb and finger muscle baselines plus seven root-position/rotation tracks.
Its two shoulder axes are calibrated to let the hands hang beside the thighs,
and it adds a small chest breathing curve. Eye and jaw tracks
are excluded so the existing gaze, expression and TTS owners retain control.

Unity's zero value is not this model's rest pose. The former sparse clip left
the other muscles at zero, which bent the elbows to approximately 100 degrees
and brought the wrists within approximately 49 mm of each other. The imported
model's elbow baseline is approximately 180 degrees. The original leg and
finger baselines likewise need explicit tracks; camera cropping cannot repair
missing pose data.

`OpenMaasoVrmIdlePoseTests` evaluates the actual reviewed VRM at the start,
middle, end and repeated idle loops. It checks separated hands, extended elbows
and knees, a stable actor root, imported muscle values and face-channel ownership.

For visual verification, run the actual receiver capture in a visible Unity
Editor with Game View and a working Metal compiler:

```sh
OPEN_MAASO_POSE_CAPTURE=/absolute/local/pose-evidence \
  "$UNITY_EDITOR" -projectPath "$PWD/unity/masso_avatar" \
  -executeMethod Maaso.Avatar.Editor.OpenMaasoVrmPoseRuntimeCapture.Begin \
  -logFile /absolute/local/pose-capture.log
```

The capture uses the original receiver and normal VRM PlayerLoop evaluation.
It samples clip times 0, 2 and 3.99 seconds, records anatomical measurements,
and renders the original world plus full front, side and hand-detail views.
The diagnostic camera temporarily isolates the same actor's renderer layers
for unobstructed inspection and restores them immediately; it does not edit
bones, geometry, skin weights or production camera behavior. These are Editor
GPU render receipts, not phone screenshots or physical-device acceptance.
