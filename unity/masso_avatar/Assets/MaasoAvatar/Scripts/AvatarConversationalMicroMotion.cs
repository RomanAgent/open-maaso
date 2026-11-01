using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Low-priority breathing and listening backchannels driven by real phase/pause
    /// edges. Restore before Animator; apply after ordinary inertia, before gaze/contact/VRM.
    /// The caller owns consent, task, foreground and mute gates. No root/legs/facial channels.</summary>
    public sealed class AvatarConversationalMicroMotion
    {
        public const float MaximumNodDegrees = 2.4f;
        public const float MaximumTiltDegrees = 1.1f;
        public const float BackchannelSeconds = 1.3f;
        public const float MinimumBackchannelInterval = 5f;
        private readonly List<Bone> bones = new(6);
        private Animator animator;
        private UnityEngine.Avatar avatar;
        private string phase = "stopped";
        private float lastNow = float.NegativeInfinity, lastCue = float.NegativeInfinity, cueAt = float.NegativeInfinity;
        private int cueNumber;
        private sealed class Bone
        {
            public Transform Transform;
            public HumanBodyBones Id;
            public Quaternion Source, Written;
            public bool Owned;
        }
        public int BoneCount => bones.Count;
        public bool HasOwnedWrites { get { foreach (Bone bone in bones) if (bone.Owned) return true; return false; } }
        public bool BackchannelActive { get; private set; }

        public void Bind(Animator value)
        {
            if (value == animator && value != null && value.avatar == avatar && bones.Count > 0) return;
            Reset(); bones.Clear(); animator = value; avatar = value != null ? value.avatar : null;
            if (value == null || !value.isHuman) return;
            foreach (HumanBodyBones id in new[] { HumanBodyBones.Chest, HumanBodyBones.UpperChest,
                HumanBodyBones.Neck, HumanBodyBones.Head, HumanBodyBones.LeftShoulder, HumanBodyBones.RightShoulder })
            {
                Transform bone = value.GetBoneTransform(id);
                if (bone != null) bones.Add(new Bone { Transform = bone, Id = id });
            }
        }

        public void SetPhase(string value, float now)
        {
            if (!Finite(now)) return;
            value = value?.Trim().ToLowerInvariant();
            if (value is not ("listening" or "thinking" or "speaking" or "stopped" or "idle") || value == phase) return;
            phase = value;
            if (value == "listening") Schedule(now, .45f);
            else { cueAt = float.NegativeInfinity; BackchannelActive = false; }
        }

        /// <summary>Only a real listening pause is eligible; speech output pauses do not fabricate nods.</summary>
        public void NotifyPause(float now)
        {
            if (phase == "listening" && Finite(now)) Schedule(now, .12f);
        }

        private void Schedule(float now, float delay)
        {
            if (now - lastCue < MinimumBackchannelInterval) return;
            cueAt = now + delay; lastCue = now; cueNumber++;
        }

        public void RestoreBeforeAnimation()
        {
            for (int i = bones.Count - 1; i >= 0; i--)
            {
                Bone bone = bones[i];
                if (bone.Owned && bone.Transform != null && Quaternion.Angle(bone.Transform.localRotation, bone.Written) < .025f)
                    bone.Transform.localRotation = bone.Source;
                bone.Owned = false;
            }
        }

        public void Apply(float now, bool allowed)
        {
            RestoreBeforeAnimation();
            if (!allowed || animator == null || !animator.isActiveAndEnabled || !Finite(now) ||
                (Finite(lastNow) && (now < lastNow || now - lastNow > .25f)))
            {
                cueAt = float.NegativeInfinity; BackchannelActive = false; lastNow = now; return;
            }
            lastNow = now;
            float t = (now - cueAt) / BackchannelSeconds;
            BackchannelActive = phase == "listening" && t >= 0f && t < 1f;
            float cue = BackchannelActive ? Mathf.Pow(Mathf.Sin(t * Mathf.PI), 2f) : 0f;
            float breath = Mathf.Sin(now * (Mathf.PI * 2f / 4.7f));
            Vector3 right = animator.transform.right, forward = animator.transform.forward;
            foreach (Bone bone in bones)
            {
                if (bone.Transform == null) continue;
                float pitch = bone.Id switch { HumanBodyBones.Chest => breath * .22f, HumanBodyBones.UpperChest => breath * .12f,
                    HumanBodyBones.Neck => cue * MaximumNodDegrees * .35f, HumanBodyBones.Head => cue * MaximumNodDegrees * .65f - breath * .08f, _ => 0f };
                float tilt = bone.Id == HumanBodyBones.Head ? cue * MaximumTiltDegrees * (cueNumber % 2 == 0 ? 1f : -1f) :
                    bone.Id == HumanBodyBones.LeftShoulder ? breath * .12f : bone.Id == HumanBodyBones.RightShoulder ? -breath * .12f : 0f;
                if (Mathf.Abs(pitch) + Mathf.Abs(tilt) < .00001f) continue;
                bone.Source = bone.Transform.localRotation;
                bone.Transform.rotation = Quaternion.AngleAxis(tilt, forward) * Quaternion.AngleAxis(pitch, right) * bone.Transform.rotation;
                bone.Written = bone.Transform.localRotation; bone.Owned = true;
            }
        }

        public void Reset()
        {
            RestoreBeforeAnimation(); phase = "stopped"; lastNow = lastCue = cueAt = float.NegativeInfinity;
            cueNumber = 0; BackchannelActive = false;
        }
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
