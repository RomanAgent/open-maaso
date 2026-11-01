using System.Collections.Generic;
using UnityEngine;

namespace Maaso.Avatar
{
    internal static class AvatarVisualBounds
    {
        public static bool TryGetCurrent(
            Transform root,
            List<Renderer> rendererBuffer,
            out Bounds bounds,
            bool includeHiddenRenderers = false)
        {
            bounds = default;
            if (root == null || rendererBuffer == null)
            {
                return false;
            }

            rendererBuffer.Clear();
            root.GetComponentsInChildren(false, rendererBuffer);
            bool hasBounds = false;

            for (int index = 0; index < rendererBuffer.Count; index++)
            {
                Renderer renderer = rendererBuffer[index];
                if (!IsBodyRenderer(renderer, includeHiddenRenderers) ||
                    !TryGetRendererBounds(renderer, out Bounds rendererBounds))
                {
                    continue;
                }

                if (!hasBounds)
                {
                    bounds = rendererBounds;
                    hasBounds = true;
                }
                else
                {
                    bounds.Encapsulate(rendererBounds);
                }
            }

            return hasBounds;
        }

        private static bool TryGetRendererBounds(Renderer renderer, out Bounds bounds)
        {
            if (renderer is SkinnedMeshRenderer skinnedRenderer &&
                TryGetSkinnedBounds(skinnedRenderer, out bounds))
            {
                return true;
            }

            bounds = renderer.bounds;
            return IsFinite(bounds.center) && IsFinite(bounds.size);
        }

        private static bool TryGetSkinnedBounds(
            SkinnedMeshRenderer renderer,
            out Bounds bounds)
        {
            bounds = default;
            if (renderer.sharedMesh == null)
            {
                return false;
            }

            var bakedMesh = new Mesh { name = $"{renderer.name}-VisualBoundsSnapshot" };
            try
            {
                renderer.BakeMesh(bakedMesh);
                Vector3[] vertices = bakedMesh.vertices;
                if (vertices.Length == 0)
                {
                    return false;
                }

                Matrix4x4 scaleFreeMatrix = Matrix4x4.TRS(
                    renderer.transform.position,
                    renderer.transform.rotation,
                    Vector3.one);
                Bounds scaledBounds = default;
                Bounds scaleFreeBounds = default;
                bool hasBounds = false;

                for (int index = 0; index < vertices.Length; index++)
                {
                    Vector3 scaledVertex = renderer.transform.TransformPoint(vertices[index]);
                    Vector3 scaleFreeVertex = scaleFreeMatrix.MultiplyPoint3x4(vertices[index]);
                    if (!IsFinite(scaledVertex) || !IsFinite(scaleFreeVertex))
                    {
                        continue;
                    }

                    if (!hasBounds)
                    {
                        scaledBounds = new Bounds(scaledVertex, Vector3.zero);
                        scaleFreeBounds = new Bounds(scaleFreeVertex, Vector3.zero);
                        hasBounds = true;
                    }
                    else
                    {
                        scaledBounds.Encapsulate(scaledVertex);
                        scaleFreeBounds.Encapsulate(scaleFreeVertex);
                    }
                }

                if (!hasBounds)
                {
                    return false;
                }

                Bounds referenceBounds = renderer.bounds;
                float scaledScore = SizeScore(scaledBounds, referenceBounds);
                float scaleFreeScore = SizeScore(scaleFreeBounds, referenceBounds);
                bounds = scaleFreeScore < scaledScore ? scaleFreeBounds : scaledBounds;
                return true;
            }
            catch (System.Exception exception)
            {
                Debug.LogWarning(
                    $"[MaasoAvatar] failed to sample current skinned bounds for {renderer.name}: {exception.Message}",
                    renderer);
                return false;
            }
            finally
            {
                if (Application.isPlaying)
                {
                    Object.Destroy(bakedMesh);
                }
                else
                {
                    Object.DestroyImmediate(bakedMesh);
                }
            }
        }

        private static float SizeScore(Bounds candidate, Bounds reference)
        {
            float candidateSize = Mathf.Max(0.0001f, candidate.size.magnitude);
            float referenceSize = Mathf.Max(0.0001f, reference.size.magnitude);
            return Mathf.Abs(Mathf.Log(candidateSize / referenceSize));
        }

        private static bool IsBodyRenderer(Renderer renderer, bool includeHiddenRenderers) =>
            renderer != null &&
            (includeHiddenRenderers || renderer.enabled) &&
            renderer.gameObject.activeInHierarchy &&
            renderer is not ParticleSystemRenderer &&
            renderer is not TrailRenderer &&
            renderer is not LineRenderer;

        private static bool IsFinite(Vector3 value) =>
            IsFinite(value.x) && IsFinite(value.y) && IsFinite(value.z);

        private static bool IsFinite(float value) =>
            !float.IsNaN(value) && !float.IsInfinity(value);
    }
}
