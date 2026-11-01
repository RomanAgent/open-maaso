using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.World
{
    [Serializable]
    public sealed class WorldMapPlayableBounds
    {
        public float minX;
        public float maxX;
        public float minZ;
        public float maxZ;

        public bool IsValid =>
            IsFinite(minX) &&
            IsFinite(maxX) &&
            IsFinite(minZ) &&
            IsFinite(maxZ) &&
            minX < maxX &&
            minZ < maxZ &&
            Mathf.Abs(minX) <= 4096f &&
            Mathf.Abs(maxX) <= 4096f &&
            Mathf.Abs(minZ) <= 4096f &&
            Mathf.Abs(maxZ) <= 4096f;

        public bool Contains(Vector3 position) =>
            IsValid &&
            position.x >= minX &&
            position.x <= maxX &&
            position.z >= minZ &&
            position.z <= maxZ;

        public bool Matches(WorldMapPlayableBounds other)
        {
            return other != null &&
                   Mathf.Abs(minX - other.minX) <= 0.001f &&
                   Mathf.Abs(maxX - other.maxX) <= 0.001f &&
                   Mathf.Abs(minZ - other.minZ) <= 0.001f &&
                   Mathf.Abs(maxZ - other.maxZ) <= 0.001f;
        }

        public WorldMapPlayableBounds Copy() => new()
        {
            minX = minX,
            maxX = maxX,
            minZ = minZ,
            maxZ = maxZ,
        };

        private static bool IsFinite(float value) =>
            !float.IsNaN(value) && !float.IsInfinity(value);
    }

}
