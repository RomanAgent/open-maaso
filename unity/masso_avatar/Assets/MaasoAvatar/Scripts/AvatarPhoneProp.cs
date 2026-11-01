using System.Collections.Generic;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>A reusable, metre-scaled smartphone: curved metal chassis,
    /// inset glass display, camera lenses, side controls and a private generic chat UI.</summary>
    public sealed class AvatarPhoneProp
    {
        public const float WidthMeters = .074f;
        public const float HeightMeters = .151f;
        public readonly GameObject Root;
        private readonly List<Object> owned = new();

        public AvatarPhoneProp(Transform parent)
        {
            Root = new GameObject("ConversationPhone");
            Root.transform.SetParent(parent, false);
            var metal = Material("Titanium rim", new Color(0.30f, 0.36f, 0.39f), 0.78f, 0.65f);
            var back = Material("Warm ceramic back", new Color(0.82f, 0.83f, 0.78f), 0.16f, 0.38f);
            var glass = Material("Black glass bezel", new Color(0.018f, 0.025f, 0.032f), 0.3f, 0.92f);
            var screen = Material("Illuminated chat display", new Color(0.15f, 0.23f, 0.29f), 0f, 0.65f, true);
            var incoming = Material("Incoming message", new Color(0.79f, 0.86f, 0.88f), 0f, 0.25f, true);
            var outgoing = Material("Reply message", new Color(0.43f, 0.78f, 0.62f), 0f, 0.25f, true);
            var lens = Material("Optical lens", new Color(0.015f, 0.08f, 0.11f), 0.75f, 0.99f);
            Plate("Rounded metal chassis", WidthMeters, HeightMeters, .009f, .010f, Vector3.zero, metal);
            Plate("Ceramic rear panel", .071f, .148f, .001f, .009f, new Vector3(0, 0, -.005f), back);
            Plate("Front glass", .071f, .148f, .001f, .009f, new Vector3(0, 0, .005f), glass);
            Plate("Active display", .065f, .136f, .0005f, .007f, new Vector3(0, 0, .0057f), screen);
            Plate("Speaker island", .022f, .005f, .0006f, .0024f, new Vector3(0, .061f, .0062f), glass);
            Plate("Conversation header", .040f, .005f, .0004f, .0018f, new Vector3(-.005f, .047f, .0062f), incoming);
            Plate("Incoming bubble 1", .040f, .016f, .0004f, .003f, new Vector3(-.007f, .025f, .0062f), incoming);
            Plate("Incoming bubble 2", .028f, .010f, .0004f, .003f, new Vector3(-.013f, .009f, .0062f), incoming);
            Plate("Reply bubble", .044f, .017f, .0004f, .003f, new Vector3(.004f, -.010f, .0062f), outgoing);
            Plate("Compose field", .052f, .008f, .0004f, .003f, new Vector3(0, -.034f, .0062f), incoming);
            for (int row = 0; row < 3; row++)
                for (int key = 0; key < 8; key++)
                    Plate("Keyboard key", .0045f, .0035f, .0003f, .0008f,
                        new Vector3((key - 3.5f) * .0065f, -.046f - row * .006f, .0062f), incoming);
            Plate("Rear camera island", .027f, .035f, .002f, .006f,
                new Vector3(-.018f, .050f, -.0064f), metal);
            Lens("Wide camera", new Vector3(-.018f, .058f, -.008f), .007f, glass, lens);
            Lens("Portrait camera", new Vector3(-.018f, .042f, -.008f), .006f, glass, lens);
            Lens("Flash", new Vector3(.002f, .056f, -.006f), .003f, back, incoming);
            Plate("Volume control", .002f, .021f, .004f, .0009f, new Vector3(-.038f, .021f, 0), metal);
            Plate("Power control", .002f, .015f, .004f, .0009f, new Vector3(.038f, .019f, 0), metal);
            Root.SetActive(false);
        }

        private Material Material(string name, Color color, float metallic, float smoothness, bool emissive = false)
        {
            var material = new Material(Shader.Find("Standard")) { name = name, color = color };
            material.SetFloat("_Metallic", metallic);
            material.SetFloat("_Glossiness", smoothness);
            if (emissive) { material.EnableKeyword("_EMISSION"); material.SetColor("_EmissionColor", color * .45f); }
            owned.Add(material);
            return material;
        }

        private void Lens(string name, Vector3 at, float radius, Material rim, Material glass)
        {
            Plate(name + " surround", radius * 2, radius * 2, .002f, radius, at, rim);
            Plate(name + " glass", radius * 1.55f, radius * 1.55f, .0008f, radius * .775f,
                at + Vector3.back * .0014f, glass);
        }

        private void Plate(string name, float width, float height, float depth, float radius, Vector3 at, Material material)
        {
            var part = new GameObject(name);
            part.transform.SetParent(Root.transform, false);
            part.transform.localPosition = at;
            Mesh mesh = RoundedPlate(width, height, depth, radius);
            owned.Add(mesh);
            part.AddComponent<MeshFilter>().sharedMesh = mesh;
            var renderer = part.AddComponent<MeshRenderer>();
            renderer.sharedMaterial = material;
            renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.On;
        }

        private static Mesh RoundedPlate(float width, float height, float depth, float radius)
        {
            const int steps = 6, count = 4 * (steps + 1);
            var vertices = new Vector3[count * 2 + 2];
            var triangles = new List<int>();
            radius = Mathf.Min(radius, Mathf.Min(width, height) * .5f);
            for (int corner = 0; corner < 4; corner++)
            {
                float cx = (corner == 0 || corner == 3 ? 1 : -1) * (width * .5f - radius);
                float cy = (corner < 2 ? 1 : -1) * (height * .5f - radius);
                for (int segment = 0; segment <= steps; segment++)
                {
                    float angle = (corner * 90f + segment * 90f / steps) * Mathf.Deg2Rad;
                    int index = corner * (steps + 1) + segment;
                    var point = new Vector3(cx + Mathf.Cos(angle) * radius, cy + Mathf.Sin(angle) * radius, depth * .5f);
                    vertices[index] = point;
                    vertices[index + count] = new Vector3(point.x, point.y, -point.z);
                }
            }
            vertices[count * 2] = Vector3.forward * depth * .5f;
            vertices[count * 2 + 1] = Vector3.back * depth * .5f;
            for (int index = 0; index < count; index++)
            {
                int next = (index + 1) % count;
                triangles.AddRange(new[] { count * 2, index, next, count * 2 + 1, next + count, index + count,
                    index, index + count, next + count, index, next + count, next });
            }
            var mesh = new Mesh { name = "Rounded smartphone surface", vertices = vertices, triangles = triangles.ToArray() };
            mesh.RecalculateNormals(); mesh.RecalculateBounds();
            return mesh;
        }

        public void Dispose()
        {
            Root.SetActive(false);
            Destroy(Root);
            foreach (Object item in owned) Destroy(item);
            owned.Clear();
        }

        private static void Destroy(Object item)
        {
            if (Application.isPlaying) Object.Destroy(item); else Object.DestroyImmediate(item);
        }
    }
}
