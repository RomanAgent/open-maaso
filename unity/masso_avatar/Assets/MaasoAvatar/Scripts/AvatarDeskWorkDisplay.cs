using System;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.Avatar
{
    /// <summary>
    /// Scene-local illustrative editor display, not a browser or project source.
    /// The furniture owner enables it only while an admitted desk pose is working.
    /// No model, network, file contents, input or independent animation loop.
    /// </summary>
    public sealed class AvatarDeskWorkDisplay : MonoBehaviour
    {
        public const string ScreenMeshName = "V2_LaptopInactiveGlassDisplay";
        public const int TextureWidth = 512, TextureHeight = 320;
        private const float FrameInterval = .125f;
        // Reviewed asset recipe: tool/blender/coastal_v2/furniture.py:712-718.
        // Its imported mesh is not CPU-readable; bounds remain available.
        private const float GlassWidth = .335f, GlassHeight = .210f;
        private const float LidTiltDegrees = 13f, Inset = .005f, FrontOffset = .0018f;
        private MeshRenderer source;
        private MeshFilter sourceFilter;
        private Transform seat, workSurface;
        private GameObject content;
        private Mesh contentMesh;
        private Material contentMaterial;
        private Texture2D texture;
        private Color32[] pixels;
        private float lastFrame = float.NegativeInfinity;
        private int animationFrame;

        public bool IsLit => content != null && content.activeInHierarchy && texture != null && CanShow();
        public Texture2D DisplayTexture => texture;
        public MeshRenderer DisplayRenderer => content != null ? content.GetComponent<MeshRenderer>() : null;
        public MeshRenderer SourceRenderer => source;

        public static AvatarDeskWorkDisplay Ensure(AvatarFurnitureAnchor anchor)
        {
            if (anchor?.WorkSurface == null || anchor.Seat == null || anchor.Id != "desk") return null;
            var rig = anchor.WorkSurface.GetComponentInParent<AvatarFurnitureRig>();
            if (rig == null || !rig.gameObject.activeInHierarchy || !anchor.Seat.IsChildOf(rig.transform)) return null;
            MeshRenderer screen = null;
            foreach (var candidate in rig.GetComponentsInChildren<MeshRenderer>(true))
            {
                if (candidate.name != ScreenMeshName) continue;
                if (screen != null) return null;
                screen = candidate;
            }
            if (screen == null || !screen.gameObject.activeInHierarchy) return null;
            var filter = screen.GetComponent<MeshFilter>();
            if (filter == null || filter.sharedMesh == null || !ReviewedBounds(filter.sharedMesh.bounds)) return null;
            var result = screen.GetComponent<AvatarDeskWorkDisplay>() ?? screen.gameObject.AddComponent<AvatarDeskWorkDisplay>();
            if (result.seat != anchor.Seat || result.workSurface != anchor.WorkSurface) result.Dispose();
            result.source = screen;
            result.sourceFilter = filter;
            result.seat = anchor.Seat;
            result.workSurface = anchor.WorkSurface;
            return result;
        }

        public void SetWorking(bool working)
        {
            if (!working || !CanShow())
            {
                Dispose();
                return;
            }
            if (IsLit) return;
            if (!CreateGraphics()) return;
            animationFrame = 0;
            lastFrame = float.NegativeInfinity;
            DrawEditor(0);
            content.SetActive(true);
        }

        public void Advance(float now)
        {
            if (content == null || texture == null) return;
            if (!CanShow() || float.IsNaN(now) || float.IsInfinity(now))
            {
                Dispose();
                return;
            }
            if (!content.activeInHierarchy) return;
            if (now >= lastFrame && now - lastFrame < FrameInterval) return;
            lastFrame = now;
            DrawEditor(++animationFrame);
        }

        private bool CanShow() => isActiveAndEnabled && source != null && source.enabled &&
            source.gameObject.activeInHierarchy && sourceFilter != null && sourceFilter.sharedMesh != null &&
            seat != null && seat.gameObject.activeInHierarchy && workSurface != null &&
            workSurface.gameObject.activeInHierarchy;

        private static bool ReviewedBounds(Bounds bounds)
        {
            var size = bounds.size;
            float angle = LidTiltDegrees * Mathf.Deg2Rad;
            float expectedY = GlassHeight * Mathf.Cos(angle) + .002f * Mathf.Sin(angle);
            float expectedZ = GlassHeight * Mathf.Sin(angle) + .002f * Mathf.Cos(angle);
            return Math.Abs(size.x - GlassWidth) < .008f && Math.Abs(size.y - expectedY) < .008f &&
                Math.Abs(size.z - expectedZ) < .008f;
        }

        private bool CreateGraphics()
        {
            var shader = Resources.Load<Shader>("MaasoDeskWorkDisplay");
            if (shader == null || !ReviewedBounds(sourceFilter.sharedMesh.bounds)) return false;
            try
            {
                float angle = LidTiltDegrees * Mathf.Deg2Rad;
                Vector3 normal = new(0, Mathf.Sin(angle), -Mathf.Cos(angle));
                Vector3 center = sourceFilter.sharedMesh.bounds.center;
                if (Vector3.Dot(source.transform.TransformDirection(normal),
                    seat.position - source.transform.TransformPoint(center)) <= 0) return false;
                Vector3 right = Vector3.Cross(normal, Vector3.up).normalized;
                Vector3 up = Vector3.Cross(right, normal).normalized;
                center += normal * FrontOffset;
                Vector3 halfRight = right * (GlassWidth * .5f - Inset);
                Vector3 halfUp = up * (GlassHeight * .5f - Inset);
                contentMesh = new Mesh { name = "Maaso desk display plane" };
                contentMesh.vertices = new[] { center - halfRight - halfUp, center + halfRight - halfUp,
                    center + halfRight + halfUp, center - halfRight + halfUp };
                contentMesh.uv = new[] { Vector2.zero, Vector2.right, Vector2.one, Vector2.up };
                contentMesh.triangles = new[] { 0, 2, 1, 0, 3, 2 };
                contentMesh.normals = new[] { normal, normal, normal, normal };
                contentMesh.RecalculateBounds();
                texture = new Texture2D(TextureWidth, TextureHeight, TextureFormat.RGBA32, false, false)
                {
                    name = "Maaso illustrative desk editor", wrapMode = TextureWrapMode.Clamp,
                    filterMode = FilterMode.Bilinear
                };
                pixels = new Color32[TextureWidth * TextureHeight];
                contentMaterial = new Material(shader) { name = "Maaso desk display material" };
                contentMaterial.SetTexture("_MainTex", texture);
                content = new GameObject("Maaso Desk Work Display");
                content.SetActive(false);
                content.layer = source.gameObject.layer;
                content.transform.SetParent(source.transform, false);
                content.AddComponent<MeshFilter>().sharedMesh = contentMesh;
                var renderer = content.AddComponent<MeshRenderer>();
                renderer.sharedMaterial = contentMaterial;
                renderer.shadowCastingMode = ShadowCastingMode.Off;
                renderer.receiveShadows = false;
                renderer.lightProbeUsage = LightProbeUsage.Off;
                renderer.reflectionProbeUsage = ReflectionProbeUsage.Off;
                return true;
            }
            catch
            {
                Dispose();
                return false;
            }
        }

        // White Frost v2 palette. This is a quiet work visualization, never a
        // fabricated progress percentage, source-code stream or success claim.
        private static readonly Color32 White = new(255, 255, 255, 255);
        private static readonly Color32 Muted = new(245, 246, 248, 255);
        private static readonly Color32 Primary = new(32, 33, 36, 255);
        private static readonly Color32 Secondary = new(95, 99, 107, 255);
        private static readonly Color32 Blue = new(59, 109, 228, 255);
        private static readonly Color32 SoftBlue = new(238, 244, 255, 255);
        private static readonly Color32 Accent = new(49, 95, 204, 255);
        private static readonly Color32 Green = new(56, 101, 79, 255);

        private void DrawEditor(int frame)
        {
            Array.Fill(pixels, White);
            Rect(0, 0, TextureWidth, 26, Muted);
            Rect(0, 26, 88, TextureHeight - 26, Muted);
            Rect(0, TextureHeight - 16, TextureWidth, 16, SoftBlue);
            Rect(12, 10, 5, 5, Secondary);
            Rect(24, 10, 5, 5, Blue);
            Rect(36, 10, 5, 5, Secondary);
            Rect(104, 10, 96, 5, Primary);
            for (int row = 0; row < 7; row++)
            {
                int y = 44 + row * 22;
                if (row == 1) Rect(8, y - 5, 72, 16, SoftBlue);
                Rect(15, y, 8, 5, row == 1 ? Blue : Secondary);
                Rect(29, y, 36 + row % 3 * 5, 4, row == 1 ? Accent : Secondary);
            }
            int current = (frame / 3) % 11;
            Rect(92, 41 + current * 21, TextureWidth - 98, 17, SoftBlue);
            for (int row = 0; row < 11; row++)
            {
                int y = 48 + row * 21;
                Rect(102, y, 5, 4, Secondary);
                int indent = row % 4 == 0 ? 0 : row % 3 * 16;
                int x = 124 + indent;
                Rect(x, y, 26 + row % 3 * 7, 5, row % 2 == 0 ? Accent : Green);
                x += 47;
                int length = 100 + row % 4 * 21;
                if (row == current) length = 24 + frame % 18 * 8;
                Rect(x, y, length, 4, Primary);
                if (row % 3 == 1) Rect(x + length + 10, y, 28, 4, Blue);
                if (row == current && (frame / 4) % 2 == 0)
                    Rect(x + length + 3, y - 2, 2, 9, Accent);
            }
            Rect(14, TextureHeight - 10, 38, 4, Accent);
            Rect(TextureWidth - 65, TextureHeight - 10, 48, 4, Secondary);
            texture.SetPixels32(pixels);
            texture.Apply(false, false);
        }

        private void Rect(int x, int y, int width, int height, Color32 color)
        {
            int endX = Math.Min(TextureWidth, x + width), endY = Math.Min(TextureHeight, y + height);
            for (int row = Math.Max(0, y); row < endY; row++)
                for (int column = Math.Max(0, x); column < endX; column++)
                    pixels[(TextureHeight - 1 - row) * TextureWidth + column] = color;
        }

        public void Dispose()
        {
            if (content != null) content.SetActive(false);
            DestroyOwned(content);
            DestroyOwned(contentMesh);
            DestroyOwned(contentMaterial);
            DestroyOwned(texture);
            content = null;
            contentMesh = null;
            contentMaterial = null;
            texture = null;
            pixels = null;
            lastFrame = float.NegativeInfinity;
            animationFrame = 0;
        }

        private static void DestroyOwned(UnityEngine.Object value)
        {
            if (value == null) return;
            if (Application.isPlaying) Destroy(value); else DestroyImmediate(value);
        }
        private void OnDisable() => Dispose();
        private void OnDestroy() => Dispose();
    }
}
