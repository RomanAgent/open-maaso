using System;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Reviewed normalized FK rotations, with only VRM-to-Unity axis conversion.
    /// These tracks never pass through Humanoid muscle limits or curve fitting.
    /// Missing authored fingers use the upstream pack's rest-hand pose.
    /// </summary>
    public sealed class OpenAnnieNormalizedPoseClip : ScriptableObject
    {
        [Serializable]
        public sealed class Track
        {
            public HumanBodyBones Bone;
            // Constant tracks have one sample. All others retain every source
            // frame; even nearly equal samples must not be decimated.
            public Quaternion[] Rotations = Array.Empty<Quaternion>();
        }

        public int Frames;
        public float FramesPerSecond = 30f;
        public bool Loop;
        public string SourceSha256;
        public string SourcePackSha256;
        public string SourceCommit = OpenAnnieMotionLibrary.UpstreamCommit;
        public Track[] Tracks = Array.Empty<Track>();
        public float Duration => Frames > 1 && FramesPerSecond > 0f
            ? (Loop ? Frames : Frames - 1) / FramesPerSecond : 0f;

        /// <summary>Allocation-free normalized quaternion SLERP, including the
        /// upstream last-to-first frame for looped clips.</summary>
        public bool TrySample(HumanBodyBones bone, float seconds, out Quaternion rotation)
        {
            rotation = Quaternion.identity;
            if (Frames < 2 || !Finite(FramesPerSecond) || FramesPerSecond <= 0f || !Finite(seconds) || Tracks == null) return false;
            for (int index = 0; index < Tracks.Length; index++)
            {
                Track track = Tracks[index];
                if (track == null || track.Bone != bone) continue;
                Quaternion[] values = track.Rotations;
                if (values == null || (values.Length != 1 && values.Length != Frames)) return false;
                if (values.Length == 1) { rotation = values[0]; return true; }
                float position = seconds * FramesPerSecond;
                if (!Finite(position)) return false;
                position = Loop ? Mathf.Repeat(position, Frames) : Mathf.Clamp(position, 0f, Frames - 1);
                int a = Mathf.FloorToInt(position);
                int b = Loop ? (a + 1) % Frames : Mathf.Min(a + 1, Frames - 1);
                rotation = Quaternion.SlerpUnclamped(values[a], values[b], position - a);
                return true;
            }
            return false;
        }

        public static bool IsArmOrFinger(HumanBodyBones bone) =>
            bone is HumanBodyBones.LeftShoulder or HumanBodyBones.RightShoulder or
                HumanBodyBones.LeftUpperArm or HumanBodyBones.RightUpperArm or
                HumanBodyBones.LeftLowerArm or HumanBodyBones.RightLowerArm or
                HumanBodyBones.LeftHand or HumanBodyBones.RightHand ||
            bone >= HumanBodyBones.LeftThumbProximal && bone <= HumanBodyBones.RightLittleDistal;

        public static float TorsoWeight(HumanBodyBones bone) => bone switch
        {
            HumanBodyBones.Spine => .55f,
            HumanBodyBones.Chest => .65f,
            HumanBodyBones.UpperChest => .75f,
            _ => 0f,
        };

        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
