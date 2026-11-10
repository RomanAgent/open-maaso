#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.Linq;
using Maaso.World;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Project-authored Humanoid gait baked from this model's verified rest
    /// pose. Feet follow an explicit stance/swing path; no third-party motion
    /// is imported. Native navigation/presence owns world motion and keeps
    /// applyRootMotion=false. The trajectory is calibration metadata only.
    /// </summary>
    public static class OpenMaasoWalkClipBuilder
    {
        public const string ClipPath = "Assets/MaasoAvatar/Animations/Humanoid/Actions/standard_walk.anim";
        public const string StancePath = "Assets/MaasoAvatar/Animations/Humanoid/Actions/OfflineWalkStance.anim";
        public const float CycleSeconds = .8f;
        public const float AuthoredMetersPerSecond = 1.6f;
        private const int Samples = 48;

        public static void Ensure(AnimatorController controller, AnimationClip idle, Animator animator)
        {
            if (controller == null || idle == null || animator == null)
                throw new ArgumentNullException("The walk needs its model and verified idle.");
            EnsureFolder("Assets/MaasoAvatar/Animations/Humanoid/Actions");
            AnimationClip walk = Clip(ClipPath, "standard_walk");
            AnimationClip stance = Clip(StancePath, "OfflineWalkStance");
            Bake(walk, idle, animator);
            CopyConstantPose(stance, idle);
            Save(walk); Save(stance);
            FloatParameter(WorldLocomotionPresentation.WorldWalkSpeedParameter);
            FloatParameter(WorldLocomotionPresentation.WorldWalkStrideParameter);
            AnimatorStateMachine machine = controller.layers[0].stateMachine;
            AnimatorState state = machine.states.Select(s => s.state).FirstOrDefault(s => s.name == "standard_walk")
                ?? machine.AddState("standard_walk");
            BlendTree tree = state.motion as BlendTree;
            if (tree == null)
            {
                tree = new BlendTree { name = "OpenMaasoWalkStride" };
                AssetDatabase.AddObjectToAsset(tree, controller);
            }
            tree.blendType = BlendTreeType.Simple1D;
            tree.blendParameter = WorldLocomotionPresentation.WorldWalkStrideParameter;
            tree.useAutomaticThresholds = false;
            tree.children = new[]
            {
                new ChildMotion { motion = stance, threshold = 0f, timeScale = 1f },
                new ChildMotion { motion = walk, threshold = 1f, timeScale = 1f },
            };
            state.motion = tree;
            state.speed = 1f;
            state.speedParameter = WorldLocomotionPresentation.WorldWalkSpeedParameter;
            state.speedParameterActive = true;
            state.iKOnFeet = false;
            EditorUtility.SetDirty(tree); EditorUtility.SetDirty(state); EditorUtility.SetDirty(controller);

            void FloatParameter(string name)
            {
                if (!controller.parameters.Any(p => p.name == name))
                    controller.AddParameter(new AnimatorControllerParameter { name = name,
                        type = AnimatorControllerParameterType.Float, defaultFloat = 1f });
            }
        }

        private static void Bake(AnimationClip clip, AnimationClip idle, Animator animator)
        {
            Transform[] transforms = animator.GetComponentsInChildren<Transform>(true);
            Vector3[] positions = transforms.Select(t => t.localPosition).ToArray();
            Quaternion[] rotations = transforms.Select(t => t.localRotation).ToArray();
            Vector3[] scales = transforms.Select(t => t.localScale).ToArray();
            Renderer[] renderers = animator.GetComponentsInChildren<Renderer>(true);
            Bounds[] bounds = renderers.Select(r => r.localBounds).ToArray();
            HumanPose imported = new HumanPose();
            using var handler = new HumanPoseHandler(animator.avatar, animator.transform);
            handler.GetHumanPose(ref imported);
            var rest = new HumanPose { bodyPosition = imported.bodyPosition,
                bodyRotation = imported.bodyRotation, muscles = (float[])imported.muscles.Clone() };
            for (int muscle = 0; muscle < rest.muscles.Length; muscle++)
            {
                var curve = AnimationUtility.GetEditorCurve(idle, EditorCurveBinding.FloatCurve("", typeof(Animator), HumanTrait.MuscleName[muscle]));
                if (curve != null) rest.muscles[muscle] = curve.Evaluate(0f);
            }
            handler.SetHumanPose(ref rest);
            var left = new Leg(animator, true);
            var right = new Leg(animator, false);
            float scale = animator.humanScale;
            var rows = new List<HumanPose>();
            try
            {
                for (int sample = 0; sample <= Samples; sample++)
                {
                    float phase = sample / (float)Samples;
                    var pose = new HumanPose { bodyPosition = rest.bodyPosition,
                        bodyRotation = rest.bodyRotation, muscles = (float[])rest.muscles.Clone() };
                    Muscle(ref pose, "Left Arm Front-Back", .15f + .12f * Mathf.Cos(phase * Mathf.PI * 2f));
                    Muscle(ref pose, "Right Arm Front-Back", .15f - .12f * Mathf.Cos(phase * Mathf.PI * 2f));
                    Muscle(ref pose, "Left Forearm Stretch", .84f);
                    Muscle(ref pose, "Right Forearm Stretch", .84f);
                    Muscle(ref pose, "Chest Twist Left-Right", .018f * Mathf.Sin(phase * Mathf.PI * 2f));
                    handler.SetHumanPose(ref pose);
                    float lp = Phase(phase), rp = Phase(phase + .5f);
                    Vector3 lf = left.FootPath(lp, animator.transform);
                    Vector3 rf = right.FootPath(rp, animator.transform);
                    float vertical = float.PositiveInfinity;
                    if (lp <= .5f) vertical = Mathf.Min(vertical, left.SupportHeightDelta(lf));
                    if (rp <= .5f) vertical = Mathf.Min(vertical, right.SupportHeightDelta(rf));
                    if (float.IsPositiveInfinity(vertical)) vertical = 0f;
                    pose.bodyPosition.y += vertical / scale;
                    handler.SetHumanPose(ref pose);
                    left.Solve(lf, animator.transform.forward);
                    right.Solve(rf, animator.transform.forward);
                    HumanPose solved = new HumanPose(); handler.GetHumanPose(ref solved);
                    solved.muscles = (float[])solved.muscles.Clone();
                    // Humanoid body/root trajectory is extracted by Unity.
                    // It calibrates WorldWalkSpeed; it must not move the actor
                    // or accumulate within its pelvis while root motion is off.
                    solved.bodyPosition.z += AuthoredMetersPerSecond * CycleSeconds * phase / scale;
                    rows.Add(solved);
                }
            }
            finally
            {
                handler.SetHumanPose(ref imported);
                // Humanoid conversion is not a bit-exact transform roundtrip.
                // Restore every authored TRS/bound, not only its muscle pose,
                // so baking must not add hundreds of VRM prefab overrides.
                for (int index = 0; index < transforms.Length; index++)
                {
                    var serialized = new SerializedObject(transforms[index]);
                    serialized.FindProperty("m_LocalPosition").vector3Value = positions[index];
                    serialized.FindProperty("m_LocalScale").vector3Value = scales[index];
                    var rotation = serialized.FindProperty("m_LocalRotation");
                    rotation.FindPropertyRelative("x").floatValue = rotations[index].x;
                    rotation.FindPropertyRelative("y").floatValue = rotations[index].y;
                    rotation.FindPropertyRelative("z").floatValue = rotations[index].z;
                    rotation.FindPropertyRelative("w").floatValue = rotations[index].w;
                    serialized.ApplyModifiedPropertiesWithoutUndo();
                }
                for (int index = 0; index < renderers.Length; index++) renderers[index].localBounds = bounds[index];
            }
            clip.ClearCurves();
            for (int muscle = 0; muscle < HumanTrait.MuscleCount; muscle++)
            {
                int bone = HumanTrait.BoneFromMuscle(muscle);
                if (bone == (int)HumanBodyBones.LeftEye || bone == (int)HumanBodyBones.RightEye || bone == (int)HumanBodyBones.Jaw) continue;
                int index = muscle;
                Curve(HumanTrait.MuscleName[muscle], p => rows[p].muscles[index]);
            }
            foreach (string axis in new[] { "x", "y", "z" })
            {
                int index = axis == "x" ? 0 : axis == "y" ? 1 : 2;
                Curve("RootT." + axis, p => rows[p].bodyPosition[index]);
            }
            foreach (string axis in new[] { "x", "y", "z", "w" })
            {
                int index = axis == "x" ? 0 : axis == "y" ? 1 : axis == "z" ? 2 : 3;
                Curve("RootQ." + axis, p => rows[p].bodyRotation[index]);
            }
            var settings = AnimationUtility.GetAnimationClipSettings(clip);
            settings.loopTime = true; settings.loopBlend = true;
            settings.loopBlendPositionY = true; settings.loopBlendPositionXZ = false;
            settings.keepOriginalPositionY = true; settings.keepOriginalPositionXZ = true;
            settings.keepOriginalOrientation = true;
            AnimationUtility.SetAnimationClipSettings(clip, settings);

            void Curve(string name, Func<int, float> read)
            {
                var keys = new Keyframe[Samples + 1];
                for (int index = 0; index <= Samples; index++)
                {
                    float delta = index == 0 ? read(1) - read(0) : index == Samples ? read(Samples) - read(Samples - 1) : (read(index + 1) - read(index - 1)) * .5f;
                    float slope = delta * Samples / CycleSeconds;
                    keys[index] = new Keyframe(index * CycleSeconds / Samples, read(index), slope, slope);
                }
                AnimationUtility.SetEditorCurve(clip, EditorCurveBinding.FloatCurve("", typeof(Animator), name), new AnimationCurve(keys));
            }
        }

        private sealed class Leg
        {
            private readonly Transform thigh, knee, foot;
            private readonly float upper, lower;
            private readonly Vector3 restFoot;
            private readonly Quaternion flatFoot;
            public Leg(Animator animator, bool left)
            {
                thigh = animator.GetBoneTransform(left ? HumanBodyBones.LeftUpperLeg : HumanBodyBones.RightUpperLeg);
                knee = animator.GetBoneTransform(left ? HumanBodyBones.LeftLowerLeg : HumanBodyBones.RightLowerLeg);
                foot = animator.GetBoneTransform(left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot);
                upper = Vector3.Distance(thigh.position, knee.position); lower = Vector3.Distance(knee.position, foot.position);
                restFoot = animator.transform.InverseTransformPoint(foot.position);
                // Center the stride on the hip plane rather than the slightly
                // rearward imported ankle. Symmetric contacts must not force
                // one straight knee and one bent knee at the loop seam.
                restFoot.z = animator.transform.InverseTransformPoint(thigh.position).z;
                flatFoot = foot.rotation;
            }
            public Vector3 FootPath(float phase, Transform root)
            {
                float halfStride = AuthoredMetersPerSecond * CycleSeconds * .25f;
                float z, lift = 0f;
                if (phase <= .5f) z = Mathf.Lerp(halfStride, -halfStride, phase * 2f);
                else
                {
                    float swing = (phase - .5f) * 2f;
                    float t = swing * swing * (3f - 2f * swing);
                    z = Mathf.Lerp(-halfStride, halfStride, t);
                    lift = .13f * Mathf.Sin(Mathf.PI * swing);
                }
                return root.TransformPoint(restFoot + new Vector3(0, lift, z));
            }
            public float SupportHeightDelta(Vector3 target)
            {
                Vector3 horizontal = target - thigh.position; horizontal.y = 0f;
                float length = (upper + lower) * .998f;
                float y = target.y + Mathf.Sqrt(Mathf.Max(.01f, length * length - horizontal.sqrMagnitude));
                return y - thigh.position.y;
            }
            public void Solve(Vector3 target, Vector3 forward)
            {
                Vector3 origin = thigh.position;
                Vector3 delta = target - origin;
                float distance = Mathf.Clamp(delta.magnitude, Mathf.Abs(upper - lower) + .001f, upper + lower - .0001f);
                Vector3 direction = delta.normalized;
                Vector3 bend = Vector3.ProjectOnPlane(forward, direction).normalized;
                float cosine = Mathf.Clamp((upper * upper + distance * distance - lower * lower) / (2f * upper * distance), -1f, 1f);
                Vector3 wantedKnee = origin + direction * (upper * cosine) + bend * (upper * Mathf.Sqrt(1f - cosine * cosine));
                thigh.rotation = Quaternion.FromToRotation(knee.position - origin, wantedKnee - origin) * thigh.rotation;
                knee.rotation = Quaternion.FromToRotation(foot.position - knee.position, target - knee.position) * knee.rotation;
                foot.rotation = flatFoot;
            }
        }

        private static void Muscle(ref HumanPose pose, string name, float value)
            => pose.muscles[Array.IndexOf(HumanTrait.MuscleName, name)] = value;
        private static float Phase(float phase) => phase - Mathf.Floor(phase);
        private static void CopyConstantPose(AnimationClip target, AnimationClip idle)
        {
            target.ClearCurves();
            foreach (var binding in AnimationUtility.GetCurveBindings(idle))
            {
                var source = AnimationUtility.GetEditorCurve(idle, binding);
                AnimationUtility.SetEditorCurve(target, binding, AnimationCurve.Constant(0f, CycleSeconds, source.Evaluate(0f)));
            }
            var settings = AnimationUtility.GetAnimationClipSettings(target); settings.loopTime = true;
            AnimationUtility.SetAnimationClipSettings(target, settings);
        }
        private static AnimationClip Clip(string path, string name)
        {
            var clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(path);
            if (clip == null) { clip = new AnimationClip { name = name, frameRate = 60f }; AssetDatabase.CreateAsset(clip, path); }
            clip.frameRate = 60f;
            return clip;
        }
        private static void Save(AnimationClip clip) { EditorUtility.SetDirty(clip); AssetDatabase.SaveAssetIfDirty(clip); }
        private static void EnsureFolder(string path)
        {
            string[] parts = path.Split('/'); string parent = parts[0];
            foreach (string part in parts.Skip(1)) { string next = parent + "/" + part; if (!AssetDatabase.IsValidFolder(next)) AssetDatabase.CreateFolder(parent, part); parent = next; }
        }
    }
}
#endif
