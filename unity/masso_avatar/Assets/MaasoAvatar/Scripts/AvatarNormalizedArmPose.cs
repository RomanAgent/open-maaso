using System.Collections.Generic;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Replays reviewed normalized FK directly on an already loaded VRM. Uses
    /// its existing control rig, or the SAME pinned UniVRM local-rotation
    /// mapping on the raw imported rig. Never creates a rig, swaps an Animator
    /// avatar, evaluates animation, or advances VRM expression/spring state.
    /// </summary>
    public sealed class AvatarNormalizedArmPose
    {
        private const float OwnershipTolerance = .025f;
        private readonly List<Binding> bindings = new(41);
        private Transform model;
        public bool Bound => model != null && bindings.Count > 0;
        public bool HasOwnedWrites { get; private set; }
        public bool UsesControlRig { get; private set; }

        private sealed class Binding
        {
            public HumanBodyBones Id;
            public Transform Bone;
            public Quaternion InitialLocal, InitialGlobal;
            public Quaternion Before, Written;
            public bool HasWrite;
        }

        /// <summary>Call once at model activation with the already initialized
        /// runtime. Passing a non-VRM/null binding explicitly selects native
        /// Humanoid retarget fallback; it is not exact source FK playback.</summary>
        public bool Bind(Vrm10Instance instance, Vrm10Runtime runtime)
        {
            Release();
            bindings.Clear();
            model = null;
            UsesControlRig = false;
            if (instance == null || runtime == null) return false;
            var controls = runtime.ControlRig;
            foreach (HumanBodyBones id in System.Enum.GetValues(typeof(HumanBodyBones)))
            {
                if (!OpenAnnieNormalizedPoseClip.IsArmOrFinger(id) &&
                    OpenAnnieNormalizedPoseClip.TorsoWeight(id) <= 0f) continue;
                if (AvatarVrmNormalizedBoneBinding.TryCapture(instance, runtime, id,
                    out Transform bone, out Quaternion initialLocal, out Quaternion initialGlobal))
                    bindings.Add(new Binding { Id = id, Bone = bone,
                        InitialLocal = initialLocal, InitialGlobal = initialGlobal });
            }
            // Never claim a working direct arm path for a partial/unmapped rig.
            foreach (var required in new[] { HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm,
                HumanBodyBones.LeftHand, HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm,
                HumanBodyBones.RightHand })
            {
                if (bindings.Exists(binding => binding.Id == required)) continue;
                bindings.Clear();
                return false;
            }
            model = instance.transform;
            UsesControlRig = controls != null;
            return true;
        }

        /// <summary>
        /// Apply after native Animator evaluation, before transition inertia and
        /// VRM's normalized-to-raw transfer. Weight is lifecycle enter/exit only;
        /// full ownership preserves arms/fingers exactly. Optional torso blending
        /// matches the source .55/.65/.75 weights and never touches gaze/face.
        /// </summary>
        public bool Apply(OpenAnnieMotionLibrary.Entry entry, float clipSeconds,
            float weight = 1f, bool includeTorso = false)
        {
            RestoreOwnedPose();
            var clip = entry?.NormalizedPose;
            if (!Bound || clip == null || clip.SourceSha256 != entry.SourceSha256 ||
                clip.SourceCommit != OpenAnnieMotionLibrary.UpstreamCommit ||
                !Finite(clipSeconds) || !Finite(weight) || weight <= 0f) return false;
            float ownership = Mathf.Clamp01(weight);
            foreach (Binding binding in bindings)
            {
                float poseWeight = OpenAnnieNormalizedPoseClip.IsArmOrFinger(binding.Id) ? ownership :
                    includeTorso ? ownership * OpenAnnieNormalizedPoseClip.TorsoWeight(binding.Id) : 0f;
                if (poseWeight <= 0f || binding.Bone == null ||
                    !clip.TrySample(binding.Id, clipSeconds, out Quaternion normalized)) continue;
                // Same formula as pinned Vrm10ControlBone.ProcessRecursively,
                // with captured initial T-pose, never current animated transforms.
                Quaternion local = UsesControlRig ? normalized : binding.InitialLocal *
                    (Quaternion.Inverse(binding.InitialGlobal) * normalized * binding.InitialGlobal);
                binding.Before = binding.Bone.localRotation;
                binding.Written = poseWeight >= 1f ? local :
                    Quaternion.Slerp(binding.Before, local, poseWeight);
                binding.Bone.localRotation = binding.Written;
                binding.HasWrite = true;
                HasOwnedWrites = true;
            }
            return HasOwnedWrites;
        }

        /// <summary>Restore before Animator evaluation or task takeover. A new
        /// animation/IK owner that has overwritten the channel always wins.</summary>
        public void RestoreOwnedPose()
        {
            foreach (Binding binding in bindings)
            {
                if (!binding.HasWrite) continue;
                if (binding.Bone != null && Quaternion.Angle(binding.Bone.localRotation,
                    binding.Written) <= OwnershipTolerance)
                    binding.Bone.localRotation = binding.Before;
                binding.HasWrite = false;
            }
            HasOwnedWrites = false;
        }

        public void Release() => RestoreOwnedPose();
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
