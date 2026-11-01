using System;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Small, local affect modulation. These amplitudes and time
    /// constants are presentation choices, not estimates of human physiology.
    /// Neutral is the exact source aperture. No timers or per-phoneme events.</summary>
    public sealed class AvatarPupilDynamics : IDisposable
    {
        public const float AttackSeconds = .45f;
        public const float RecoverySeconds = 1.1f;
        public const float ArousalDeadzone = .15f;
        private AvatarPupilMorphPresentation morph;
        private readonly AvatarPupilMaterialAdapter material = new();
        private float current, lastFrame = float.NaN;
        public bool IsBound => morph != null && morph.IsBound || material.IsBound;
        public float NormalizedDilation => current;

        public void Bind(Transform root, bool bundledJoy)
        {
            Dispose();
            if (root == null) return;
            if (bundledJoy)
            {
                foreach (var eye in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
                {
                    Mesh mesh = eye.sharedMesh;
                    if (mesh == null || !eye.name.Equals("Joy_eye", StringComparison.Ordinal)) continue;
                    int aperture = mesh.GetBlendShapeIndex("eye_dilate");
                    if (aperture < 0) continue;
                    morph = eye.GetComponent<AvatarPupilMorphPresentation>() ??
                        eye.gameObject.AddComponent<AvatarPupilMorphPresentation>();
                    morph.Bind(eye, aperture);
                    return;
                }
                return;
            }
            // The material adapter admits only the inspected Matt source rig
            // and eye slots; unknown user models retain their source appearance.
            material.Bind(root);
        }

        public static float ResolveArousal(float surprised, float angry, float happy,
            float love, float thinking, float sad, float browConcern, float relaxed, float tired)
        {
            float stimulation = Mathf.Max(Unit(surprised), Unit(angry) * .65f);
            stimulation = Mathf.Max(stimulation, Unit(happy) * .32f);
            stimulation = Mathf.Max(stimulation, Unit(love) * .28f);
            stimulation = Mathf.Max(stimulation, Unit(thinking) * .18f);
            stimulation = Mathf.Max(stimulation, Unit(sad) * .12f);
            stimulation = Mathf.Max(stimulation, Unit(browConcern) * .2f);
            float raw = stimulation * (1f - Mathf.Max(Unit(relaxed), Unit(tired)) * .65f);
            // Generic waiting/thinking and speaking presets contain small
            // inferred brow/smile values. They are not a new emotional episode.
            // A continuous deadzone keeps those ordinary turns source-neutral.
            return Mathf.InverseLerp(ArousalDeadzone, 1f, raw);
        }

        public void Advance(float now, float arousal)
        {
            if (!IsBound || float.IsNaN(now) || float.IsInfinity(now)) return;
            float target = Unit(arousal);
            if (float.IsNaN(lastFrame)) { lastFrame = now; Present(); return; }
            float delta = Mathf.Clamp(now - lastFrame, 0f, .1f);
            if (now >= lastFrame) lastFrame = now;
            float seconds = target > current ? AttackSeconds : RecoverySeconds;
            current = Mathf.Lerp(current, target, 1f - Mathf.Exp(-delta / seconds));
            if (target == 0f && current < .001f) current = 0f;
            Present();
        }

        private static float Unit(float value) => float.IsNaN(value) || float.IsInfinity(value)
            ? 0f : Mathf.Clamp01(value);

        public void Present()
        {
            morph?.SetNormalized(current);
            material.ApplyNormalized(current);
        }

        public void Reset()
        {
            current = 0f; lastFrame = float.NaN;
            morph?.SetNormalized(0f);
            material.Reset();
        }

        public void Dispose()
        {
            Reset();
            morph?.Release(); morph = null;
            material.Dispose();
        }
    }
}
