using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Measured, model-owned native idle reference. Unity Humanoid can alter
    /// axial roll without moving the next joint; restore the authored baseline
    /// while retaining the Animator's actual delta and native-state blend.
    /// No angles, bone proportions, visual offsets or solver targets are tuned.
    /// </summary>
    public sealed class AvatarHumanoidSourceIdlePose : MonoBehaviour
    {
        [Serializable]
        private sealed class Entry
        {
            public Transform Bone;
            public string Path;
            public Vector3 NativePosition, SourcePosition, NativeScale, SourceScale;
            public Quaternion NativeRotation, SourceRotation;
            [NonSerialized] public Vector3 InputPosition, InputScale, WrittenPosition, WrittenScale;
            [NonSerialized] public Quaternion InputRotation, WrittenRotation;
            [NonSerialized] public bool OwnsPosition, OwnsRotation, OwnsScale;
        }

        [SerializeField] private Animator capturedAnimator;
        [SerializeField] private AnimationClip nativeIdleClip;
        [SerializeField] private string sourceSha256;
        [SerializeField] private Entry[] entries = Array.Empty<Entry>();
        [SerializeField] private bool captured;
        private Animator boundAnimator;
        private UnityEngine.Avatar boundAvatar;
        private const float PositionOwnershipTolerance = .000002f;
        private const float RotationOwnershipTolerance = .002f;

        public bool IsCaptured => captured && capturedAnimator != null && nativeIdleClip != null &&
            sourceSha256 != null && sourceSha256.Length == 64 && entries != null && entries.Length == 102;
        public int BoneCount => entries != null && entries.Length > 0 ? entries.Length - 1 : 0;
        public int TransformCount => entries?.Length ?? 0;
        public string SourceSha256 => sourceSha256;
        public AnimationClip NativeIdleClip => nativeIdleClip;
        public float Weight { get; private set; }
        public bool HasOwnedWrites => entries != null && entries.Any(entry => entry != null &&
            (entry.OwnsPosition || entry.OwnsRotation || entry.OwnsScale));

#if UNITY_EDITOR
        /// <summary>Both references must already be evaluated from the same
        /// immutable FBX and authored time. Does not sample or mutate the source.</summary>
        public void Capture(Animator nativeReference, Transform genericSourceRoot,
            AnimationClip nativeClip, string sourceFileSha256)
        {
            Reset();
            if (nativeReference == null || !nativeReference.isHuman || genericSourceRoot == null ||
                nativeClip == null || !nativeClip.humanMotion || sourceFileSha256?.Length != 64)
                throw new InvalidOperationException("An actual Human reference and same-file Generic source are required.");
            Transform targetRoot = transform;
            Transform[] targetBoneRoots = targetRoot.GetComponentsInChildren<Transform>(true)
                .Where(bone => bone.name == "CC_Base_BoneRoot").ToArray();
            Transform[] sourceBoneRoots = genericSourceRoot.GetComponentsInChildren<Transform>(true)
                .Where(bone => bone.name == "CC_Base_BoneRoot").ToArray();
            if (targetBoneRoots.Length != 1 || sourceBoneRoots.Length != 1 ||
                targetBoneRoots[0].parent == null || sourceBoneRoots[0].parent == null ||
                targetBoneRoots[0].parent == targetRoot || sourceBoneRoots[0].parent == genericSourceRoot)
                throw new InvalidOperationException("Keep the real Armature and all 101 source bones; never sample the actor wrapper.");
            Transform targetRig = targetBoneRoots[0].parent, sourceRig = sourceBoneRoots[0].parent;
            if (targetRig.name != "Armature" || sourceRig.name != "Armature")
                throw new InvalidOperationException("Only the reviewed Matt Armature hierarchy is supported.");
            var source = sourceRig.GetComponentsInChildren<Transform>(true)
                .ToDictionary(bone => RelativePath(bone, sourceRig));
            Transform[] target = targetRig.GetComponentsInChildren<Transform>(true);
            if (target.Length != 102 || source.Count != 102)
                throw new InvalidOperationException("Matt source reference must contain Armature plus 101 exact bones.");
            var measured = new List<Entry>(target.Length);
            foreach (Transform bone in target)
            {
                string path = RelativePath(bone, targetRig);
                if (!source.TryGetValue(path, out Transform authored) ||
                    !Finite(bone.localPosition) || !Finite(authored.localPosition) ||
                    !Finite(bone.localScale) || !Finite(authored.localScale) ||
                    !Valid(bone.localRotation) || !Valid(authored.localRotation) ||
                    !PositiveScale(bone.localScale) || !PositiveScale(authored.localScale))
                    throw new InvalidOperationException("Source/native reference mismatch at " + path);
                measured.Add(new Entry { Bone = bone, Path = "Armature" + (path.Length == 0 ? "" : "/" + path),
                    NativePosition = bone.localPosition, SourcePosition = authored.localPosition,
                    NativeRotation = bone.localRotation, SourceRotation = authored.localRotation,
                    NativeScale = bone.localScale, SourceScale = authored.localScale });
            }
            capturedAnimator = nativeReference;
            nativeIdleClip = nativeClip;
            sourceSha256 = sourceFileSha256;
            entries = measured.ToArray();
            captured = true;
            if (!Bind(nativeReference)) throw new InvalidOperationException("Measured source reference failed its own binding.");
        }
#endif

        public bool Bind(Animator target)
        {
            if (boundAnimator == target && target != null && target.avatar == boundAvatar && IsCaptured) return true;
            Reset();
            boundAnimator = null; boundAvatar = null;
            if (!IsCaptured || target != capturedAnimator || !target.isHuman ||
                target.avatar == null || !target.avatar.isValid ||
                entries.Any(entry => entry == null || entry.Bone == null || entry.Bone == transform ||
                    !entry.Bone.IsChildOf(transform))) return false;
            boundAnimator = target; boundAvatar = target.avatar;
            return true;
        }

        /// <summary>Receiver Update, after later overlay owners restore and
        /// before Animator evaluates. Restore only properties we still own.</summary>
        public void RestoreBeforeAnimation()
        {
            if (entries == null) return;
            foreach (Entry entry in entries)
            {
                if (entry?.Bone == null) continue;
                if (entry.OwnsPosition && Vector3.Distance(entry.Bone.localPosition, entry.WrittenPosition) <= PositionOwnershipTolerance)
                    entry.Bone.localPosition = entry.InputPosition;
                if (entry.OwnsRotation && Quaternion.Angle(entry.Bone.localRotation, entry.WrittenRotation) <= RotationOwnershipTolerance)
                    entry.Bone.localRotation = entry.InputRotation;
                if (entry.OwnsScale && Vector3.Distance(entry.Bone.localScale, entry.WrittenScale) <= PositionOwnershipTolerance)
                    entry.Bone.localScale = entry.InputScale;
                entry.OwnsPosition = entry.OwnsRotation = entry.OwnsScale = false;
            }
        }

        /// <summary>After Animator, before TTS, gaze, speech/contact owners.
        /// A new ordinary action fades the reference with its outgoing native
        /// idle contribution. A hard task owner passes allowed=false.</summary>
        public void Apply(Animator target, bool allowed = true)
        {
            // Also safe for manual Editor stepping without a Receiver Update.
            RestoreBeforeAnimation();
            if (!allowed || !Bind(target) || !target.isActiveAndEnabled || target.runtimeAnimatorController == null)
            { Weight = 0f; return; }
            Weight = NativeContribution(target);
            if (float.IsNaN(Weight) || float.IsInfinity(Weight)) { Weight = 0f; return; }
            if (Weight <= .000001f) return;
            foreach (Entry entry in entries)
            {
                Transform bone = entry.Bone;
                Vector3 position = bone.localPosition, scale = bone.localScale;
                Quaternion rotation = bone.localRotation;
                if (!Finite(position) || !Finite(scale) || !Valid(rotation)) continue;
                // The measured right offset preserves the Animator's current
                // orientation delta. At the native reference this is exactly
                // the authored source orientation, with no cumulative input.
                Quaternion source = rotation * Quaternion.Inverse(entry.NativeRotation) * entry.SourceRotation;
                Vector3 sourcePosition = position + (entry.SourcePosition - entry.NativePosition);
                Vector3 sourceScale = Vector3.Scale(scale, new Vector3(
                    entry.SourceScale.x / entry.NativeScale.x,
                    entry.SourceScale.y / entry.NativeScale.y,
                    entry.SourceScale.z / entry.NativeScale.z));
                entry.InputPosition = position; entry.InputRotation = rotation; entry.InputScale = scale;
                entry.WrittenPosition = Vector3.LerpUnclamped(position, sourcePosition, Weight);
                entry.WrittenRotation = Quaternion.SlerpUnclamped(rotation, source, Weight);
                entry.WrittenScale = Vector3.LerpUnclamped(scale, sourceScale, Weight);
                bone.localPosition = entry.WrittenPosition; bone.localRotation = entry.WrittenRotation; bone.localScale = entry.WrittenScale;
                entry.OwnsPosition = entry.OwnsRotation = entry.OwnsScale = true;
            }
        }

        private float NativeContribution(Animator animator)
        {
            bool transition = animator.IsInTransition(0);
            float current = StateContribution(animator.GetCurrentAnimatorStateInfo(0), animator.GetCurrentAnimatorClipInfo(0));
            float next = transition ? StateContribution(animator.GetNextAnimatorStateInfo(0), animator.GetNextAnimatorClipInfo(0)) : 0f;
            // Real Unity current/next clip weights already contain the state
            // crossfade. Multiplying transition.normalizedTime again squares
            // its fade and releases the authored baseline prematurely.
            return Mathf.Clamp01(current + next);
        }

        private float StateContribution(AnimatorStateInfo state, AnimatorClipInfo[] clips)
        {
            if (!state.IsName(AvatarConversationMotionPolicy.BaseIdleState) &&
                !state.IsName("Base Layer." + AvatarConversationMotionPolicy.BaseIdleState)) return 0f;
            float weight = 0f;
            foreach (AnimatorClipInfo clip in clips) if (clip.clip == nativeIdleClip) weight += clip.weight;
            return Mathf.Clamp01(weight);
        }

        public void Reset() { RestoreBeforeAnimation(); Weight = 0f; }

        private static string RelativePath(Transform bone, Transform root)
        {
            var names = new Stack<string>();
            for (Transform current = bone; current != null && current != root; current = current.parent) names.Push(current.name);
            return string.Join("/", names);
        }
        private static bool PositiveScale(Vector3 value) => value.x > .00001f && value.y > .00001f && value.z > .00001f;
        private static bool Finite(Vector3 value) => !float.IsNaN(value.x) && !float.IsNaN(value.y) && !float.IsNaN(value.z) &&
            !float.IsInfinity(value.x) && !float.IsInfinity(value.y) && !float.IsInfinity(value.z);
        private static bool Valid(Quaternion value) => !float.IsNaN(value.x) && !float.IsNaN(value.y) && !float.IsNaN(value.z) && !float.IsNaN(value.w) &&
            !float.IsInfinity(value.x) && !float.IsInfinity(value.y) && !float.IsInfinity(value.z) && !float.IsInfinity(value.w) &&
            value.x * value.x + value.y * value.y + value.z * value.z + value.w * value.w > .1f;
    }
}
