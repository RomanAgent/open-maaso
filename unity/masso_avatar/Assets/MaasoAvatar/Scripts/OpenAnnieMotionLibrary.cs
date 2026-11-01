using System;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Official CC0 normalized poses and native retarget fallbacks.
    /// Body, face and task ownership remain with the existing avatar runtime.</summary>
    public sealed class OpenAnnieMotionLibrary : ScriptableObject
    {
        public const string ResourceName = "OpenAnnieMotionLibrary";
        public const string IdPrefix = "annie_";
        public const string UpperBodyLayerName = "Annie Upper Body";
        public const string EmptyUpperBodyState = "annie_upper_body_empty";
        public const string UpstreamCommit = "1a3aebfe32343b119263c8b7eba3b7cb1d4e4507";

        [Serializable]
        public sealed class Entry
        {
            public string Id;
            public AnimationClip Clip;
            public OpenAnnieNormalizedPoseClip NormalizedPose;
            public bool UpperBody;
            public bool Loop;
            public float Duration;
            public string Category;
            public string Layer;
            public string Description;
            public string Energy;
            public string Hands;
            public string Rest;
            public bool Contact;
            public float PreparationEnd = -1f;
            public float Stroke = -1f;
            public float RetractionStart = -1f;
            public float[] Strokes = Array.Empty<float>();
            public string SourceSha256;
        }

        public Entry[] Entries = Array.Empty<Entry>();
        public string SourceCommit = UpstreamCommit;
        public string License = "CC0-1.0";

        public bool TryGet(string id, out Entry entry)
        {
            foreach (Entry candidate in Entries)
            {
                if (candidate != null && string.Equals(candidate.Id, id, StringComparison.Ordinal))
                {
                    entry = candidate;
                    return true;
                }
            }
            entry = null;
            return false;
        }
    }
}
