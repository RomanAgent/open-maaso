using System.Collections.Generic;
using Maaso.Avatar;
using UnityEngine;

namespace Maaso.World
{
    public static class WorldAvatarGrounding
    {
        // Renderer bounds can contain a few millimetres of invisible padding below
        // the visible sole. Sink that padding into the floor so feet read as being
        // in contact without visibly clipping the shoe or bare-foot mesh.
        public const float GroundContactInset = 0.008f;

        public static bool TryGround(
            Transform visualRoot,
            float groundY,
            out float appliedOffset)
        {
            appliedOffset = 0f;
            if (visualRoot == null || !IsFinite(groundY))
            {
                return false;
            }

            var renderers = new List<Renderer>();
            if (!AvatarVisualBounds.TryGetCurrent(visualRoot, renderers, out Bounds bodyBounds))
            {
                return false;
            }

            float contactY = groundY - GroundContactInset;
            float offset = contactY - bodyBounds.min.y;
            Vector3 nextPosition = visualRoot.position + (Vector3.up * offset);
            if (!IsFinite(offset) || !IsFinite(nextPosition))
            {
                return false;
            }

            visualRoot.position = nextPosition;
            appliedOffset = offset;
            return true;
        }

        private static bool IsFinite(Vector3 value) =>
            IsFinite(value.x) && IsFinite(value.y) && IsFinite(value.z);

        private static bool IsFinite(float value) =>
            !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
