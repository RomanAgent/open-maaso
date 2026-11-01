using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

namespace Maaso.World.Editor
{
    /// <summary>Imports display-referred Cycles atlases onto the original 3D room meshes.</summary>
    public static class CoastalRoomV2Importer
    {
        public const string AssetRoot = "Assets/MaasoWorld/PersonalSpace/CoastalV2";
        public const string ManifestPath = AssetRoot + "/manifest.json";

        [Serializable]
        public sealed class MaterialEntry
        {
            public string name;
            public string texture;
            public float opacity = 1f;
            // Standard culls back faces. The exporter must supply visible back-face geometry.
            public bool doubleSided;
        }

        [Serializable]
        public sealed class MeshEntry
        {
            public string name;
            public string material;
            public int triangles;
        }

        [Serializable]
        public sealed class CameraEntry
        {
            public string name;
            public float[] position;
            public float[] target;
            public float lens;
            public float ortho;
            public string type;
        }

        [Serializable]
        public sealed class Manifest
        {
            public int version;
            public float roomSize;
            public float roomHeight;
            public int bedCount;
            public string sourceSha256;
            public string colorTransform;
            public string axes;
            public MaterialEntry[] materials;
            public MeshEntry[] meshes;
            public CameraEntry[] cameras;
        }

        public static Manifest ReadManifest()
        {
            string path = ProjectFile(ManifestPath);
            if (!File.Exists(path)) throw new FileNotFoundException("Export the Coastal V2 room before building Unity assets.", path);
            return ParseManifest(File.ReadAllText(path));
        }

        public static Manifest ParseManifest(string json)
        {
            Manifest manifest = JsonUtility.FromJson<Manifest>(json);
            if (manifest == null || manifest.version != 2 ||
                !Finite(manifest.roomSize) || !Finite(manifest.roomHeight) ||
                Mathf.Abs(manifest.roomSize - 8f) > .001f ||
                Mathf.Abs(manifest.roomHeight - 3.2f) > .001f || manifest.bedCount != 0)
                throw new InvalidDataException("Expected a Coastal V2 manifest for an 8 x 8 x 3.2 m room without a bed.");
            if (manifest.materials == null || manifest.materials.Length == 0 ||
                manifest.meshes == null || manifest.meshes.Length == 0 || manifest.cameras == null)
                throw new InvalidDataException("The room manifest requires materials, meshes and cameras.");
            var materials = new HashSet<string>(StringComparer.Ordinal);
            foreach (MaterialEntry entry in manifest.materials)
            {
                if (entry == null || string.IsNullOrEmpty(entry.name) ||
                    !entry.name.StartsWith("Baked_", StringComparison.Ordinal) ||
                    entry.name.Any(c => !char.IsLetterOrDigit(c) && c != '_') ||
                    !materials.Add(entry.name) || !Finite(entry.opacity) || entry.opacity < 0f || entry.opacity > 1f)
                    throw new InvalidDataException("Invalid or duplicate baked material in the room manifest.");
                ResolveTexturePath(entry.texture);
            }
            var meshes = new HashSet<string>(StringComparer.Ordinal);
            foreach (MeshEntry entry in manifest.meshes)
            {
                if (entry == null || string.IsNullOrEmpty(entry.name) ||
                    !entry.name.StartsWith("V2_", StringComparison.Ordinal) || !meshes.Add(entry.name) ||
                    !materials.Contains(entry.material ?? string.Empty) || entry.triangles <= 0)
                    throw new InvalidDataException("Invalid mesh-to-atlas binding in the room manifest.");
                if (HasBedToken(entry.name)) throw new InvalidDataException("A bed mesh cannot enter the Coastal V2 room.");
            }
            var cameras = new HashSet<string>(StringComparer.Ordinal);
            foreach (CameraEntry entry in manifest.cameras)
            {
                if (entry == null || string.IsNullOrEmpty(entry.name) || !cameras.Add(entry.name) ||
                    !Finite(entry.lens) || entry.lens <= 0f)
                    throw new InvalidDataException("Invalid or duplicate room camera.");
                if ((BlenderToUnity(entry.target) - BlenderToUnity(entry.position)).sqrMagnitude < .000001f)
                    throw new InvalidDataException("A room camera needs a nonzero viewing direction.");
            }
            foreach (string view in CoastalRoomV2Capture.StandardViews)
                if (!cameras.Contains(view)) throw new InvalidDataException("Missing comparison camera: " + view);
            return manifest;
        }

        public static string ResolveTexturePath(string texture)
        {
            if (string.IsNullOrWhiteSpace(texture) || texture.Contains('\\') || texture.Contains(':'))
                throw new InvalidDataException("A baked texture must be a local path inside CoastalV2.");
            string path = texture.StartsWith("Assets/", StringComparison.Ordinal) ? texture : AssetRoot + "/" + texture;
            if (!path.StartsWith(AssetRoot + "/", StringComparison.Ordinal) ||
                path.Split('/').Any(part => part == ".." || part == "." || part.Length == 0) ||
                !path.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("A baked PNG path escaped the CoastalV2 asset directory.");
            return path;
        }

        public static Vector3 BlenderToUnity(float[] value)
        {
            if (value == null || value.Length != 3 || value.Any(v => !Finite(v)))
                throw new InvalidDataException("Camera positions must contain three finite Blender coordinates.");
            // Match the FBX export's half-turn and Unity handedness conversion.
            return new Vector3(-value[0], value[2], -value[1]);
        }

        public static string ProjectFile(string assetPath) =>
            Path.GetFullPath(Path.Combine(Application.dataPath, "..", assetPath));

        public static void ConfigureModel(GameObject model)
        {
            if (model == null) throw new ArgumentNullException(nameof(model));
            Manifest manifest = ReadManifest();
            int layer = LayerMask.NameToLayer("PersonalSpaceEnvironment");
            if (layer < 0) throw new InvalidOperationException("The personal-space environment layer is missing.");
            Dictionary<string, Material> materials = ImportMaterials(manifest);
            Dictionary<string, MeshEntry> entries = manifest.meshes.ToDictionary(item => item.name, StringComparer.Ordinal);
            foreach (Collider collider in model.GetComponentsInChildren<Collider>(true)) Object.DestroyImmediate(collider);
            foreach (Light light in model.GetComponentsInChildren<Light>(true)) Object.DestroyImmediate(light);
            Renderer[] renderers = model.GetComponentsInChildren<Renderer>(true);
            if (renderers.Length != entries.Count) throw new InvalidDataException("FBX renderer count does not match its bake manifest.");
            foreach (Renderer renderer in renderers)
            {
                Mesh geometry = renderer.GetComponent<MeshFilter>()?.sharedMesh;
                entries.TryGetValue(renderer.name, out MeshEntry expected);
                Debug.Log($"[CoastalV2][Topology] {renderer.name} triangles={geometry?.triangles.Length / 3} expected={expected?.triangles} vertices={geometry?.vertexCount} uv={geometry?.uv.Length} submeshes={geometry?.subMeshCount}");
            }
            foreach (Renderer renderer in renderers)
            {
                if (!entries.TryGetValue(renderer.name, out MeshEntry entry))
                    throw new InvalidDataException("Unexpected FBX renderer: " + renderer.name);
                Mesh mesh = renderer.GetComponent<MeshFilter>()?.sharedMesh;
                if (mesh == null || mesh.triangles.Length / 3 != entry.triangles ||
                    mesh.uv.Length != mesh.vertexCount || mesh.subMeshCount != 1)
                    throw new InvalidDataException($"The FBX changed atlas topology or lost UVs: {renderer.name}; triangles={mesh?.triangles.Length / 3}, expected={entry.triangles}, vertices={mesh?.vertexCount}, uv={mesh?.uv.Length}, submeshes={mesh?.subMeshCount}");
                renderer.gameObject.layer = layer;
                renderer.sharedMaterials = new[] { materials[entry.material] };
                renderer.shadowCastingMode = ShadowCastingMode.Off;
                renderer.receiveShadows = false;
                renderer.lightProbeUsage = LightProbeUsage.Off;
                renderer.reflectionProbeUsage = ReflectionProbeUsage.Off;
                renderer.lightmapIndex = -1;
                StaticEditorFlags flags = StaticEditorFlags.BatchingStatic | StaticEditorFlags.OccludeeStatic;
                if (materials[entry.material].GetFloat("_Mode") == 0f) flags |= StaticEditorFlags.OccluderStatic;
                GameObjectUtility.SetStaticEditorFlags(renderer.gameObject, flags);
            }
        }

        private static Dictionary<string, Material> ImportMaterials(Manifest manifest)
        {
            string directory = AssetRoot + "/Materials";
            if (!AssetDatabase.IsValidFolder(directory)) AssetDatabase.CreateFolder(AssetRoot, "Materials");
            var result = new Dictionary<string, Material>(StringComparer.Ordinal);
            foreach (MaterialEntry entry in manifest.materials)
            {
                string texturePath = ResolveTexturePath(entry.texture);
                if (!File.Exists(ProjectFile(texturePath))) throw new FileNotFoundException("Missing baked atlas.", texturePath);
                var importer = AssetImporter.GetAtPath(texturePath) as TextureImporter;
                if (importer == null)
                {
                    AssetDatabase.ImportAsset(texturePath, ImportAssetOptions.ForceSynchronousImport);
                    importer = AssetImporter.GetAtPath(texturePath) as TextureImporter;
                }
                if (importer == null) throw new InvalidDataException("No texture importer for " + texturePath);
                string previousSettings = EditorJsonUtility.ToJson(importer);
                importer.textureType = TextureImporterType.Default;
                importer.sRGBTexture = true;
                importer.isReadable = false;
                importer.mipmapEnabled = true;
                importer.alphaSource = entry.opacity < 1f ? TextureImporterAlphaSource.FromInput : TextureImporterAlphaSource.None;
                importer.alphaIsTransparency = entry.opacity < 1f;
                importer.wrapMode = TextureWrapMode.Clamp;
                importer.filterMode = FilterMode.Trilinear;
                importer.anisoLevel = 4;
                importer.npotScale = TextureImporterNPOTScale.None;
                importer.maxTextureSize = 4096;
                importer.textureCompression = TextureImporterCompression.CompressedHQ;
                importer.compressionQuality = 100;
                foreach (string platform in new[] { "iPhone", "Android" })
                {
                    TextureImporterPlatformSettings settings = importer.GetPlatformTextureSettings(platform);
                    settings.name = platform;
                    settings.overridden = true;
                    settings.maxTextureSize = 4096;
                    settings.format = TextureImporterFormat.ASTC_4x4;
                    settings.compressionQuality = 100;
                    importer.SetPlatformTextureSettings(settings);
                }
                if (EditorJsonUtility.ToJson(importer) != previousSettings)
                    importer.SaveAndReimport();
                Texture2D texture = AssetDatabase.LoadAssetAtPath<Texture2D>(texturePath);
                string materialPath = directory + "/" + entry.name + ".mat";
                Material material = AssetDatabase.LoadAssetAtPath<Material>(materialPath);
                if (material == null)
                {
                    material = new Material(RequireBakedShader()) { name = entry.name };
                    AssetDatabase.CreateAsset(material, materialPath);
                }
                ApplyBakedMaterial(material, texture, entry.opacity);
                material.doubleSidedGI = entry.doubleSided;
                EditorUtility.SetDirty(material);
                result.Add(entry.name, material);
            }
            return result;
        }

        public static void ApplyBakedMaterial(Material material, Texture texture, float opacity)
        {
            if (material == null || texture == null || !Finite(opacity) || opacity < 0f || opacity > 1f)
                throw new ArgumentException("A baked material requires a texture and opacity in [0, 1].");
            material.shader = RequireBakedShader();
            material.enableInstancing = true;
            material.mainTexture = texture;
            material.mainTextureScale = Vector2.one;
            material.mainTextureOffset = Vector2.zero;
            material.color = new Color(0f, 0f, 0f, opacity);
            material.SetTexture("_EmissionMap", texture);
            material.SetColor("_EmissionColor", Color.white);
            material.EnableKeyword("_EMISSION");
            material.EnableKeyword("_GLOSSYREFLECTIONS_OFF");
            material.EnableKeyword("_SPECULARHIGHLIGHTS_OFF");
            material.SetFloat("_GlossyReflections", 0f);
            material.SetFloat("_SpecularHighlights", 0f);
            material.SetFloat("_Metallic", 0f);
            material.SetFloat("_Glossiness", 0f);
            material.SetFloat("_OcclusionOpacity", 1f);
            material.DisableKeyword("_NORMALMAP");
            material.DisableKeyword("_METALLICGLOSSMAP");
            material.SetTexture("_BumpMap", null);
            material.SetTexture("_MetallicGlossMap", null);
            material.SetTexture("_OcclusionMap", null);
            material.globalIlluminationFlags = MaterialGlobalIlluminationFlags.None;
            bool transparent = opacity < 1f;
            material.SetFloat("_Mode", transparent ? 2f : 0f);
            material.SetInt("_SrcBlend", (int)(transparent ? BlendMode.SrcAlpha : BlendMode.One));
            material.SetInt("_DstBlend", (int)(transparent ? BlendMode.OneMinusSrcAlpha : BlendMode.Zero));
            material.SetInt("_ZWrite", transparent ? 0 : 1);
            material.DisableKeyword("_ALPHATEST_ON");
            material.DisableKeyword("_ALPHAPREMULTIPLY_ON");
            if (transparent) material.EnableKeyword("_ALPHABLEND_ON");
            else material.DisableKeyword("_ALPHABLEND_ON");
            material.SetOverrideTag("RenderType", transparent ? "Transparent" : "Opaque");
            material.renderQueue = transparent ? (int)RenderQueue.Transparent : -1;
        }

        public static void ValidateGeometry(GameObject model)
        {
            Renderer[] all = model.GetComponentsInChildren<Renderer>(true);
            if (all.Length < 12) throw new InvalidDataException("The baked room must retain separate 3D walls and furniture.");
            var names = all.Select(item => item.name).ToHashSet(StringComparer.Ordinal);
            foreach (string required in new[] { "V2_Floor_Baked", "V2_West_Wall", "V2_East_Wall", "V2_Ceiling", "V2_Distant_Ocean" })
                if (!names.Contains(required)) throw new InvalidDataException("Missing Coastal V2 geometry: " + required);
            if (model.GetComponentsInChildren<Transform>(true).Any(item => HasBedToken(item.name) || item.name.Contains("PREVIEW_ONLY")))
                throw new InvalidDataException("Bed or preview geometry leaked into the runtime room.");
            Bounds floor = GeometryBounds(all.Single(item => item.name == "V2_Floor_Baked"));
            Bounds west = GeometryBounds(all.Single(item => item.name == "V2_West_Wall"));
            Bounds east = GeometryBounds(all.Single(item => item.name == "V2_East_Wall"));
            Bounds ceiling = GeometryBounds(all.Single(item => item.name == "V2_Ceiling"));
            RequireNear(floor.min.x, -4f, "floor east"); RequireNear(floor.max.x, 4f, "floor west");
            RequireNear(floor.min.z, -4f, "floor north"); RequireNear(floor.max.z, 4f, "floor south");
            RequireNear(floor.max.y, 0f, "finished floor");
            RequireNear(west.min.x, 4f, "west inner wall"); RequireNear(east.max.x, -4f, "east inner wall");
            RequireNear(ceiling.min.y, 3.2f, "ceiling underside");
            if (GeometryBounds(all.Single(item => item.name == "V2_Distant_Ocean")).center.z >= -4f)
                throw new InvalidDataException("The ocean must remain outside the north window.");
            if (!all.Any(item => item.name.StartsWith("V2_Sofa", StringComparison.Ordinal)) ||
                !all.Any(item => item.name.StartsWith("V2_WorkDesk", StringComparison.Ordinal)))
                throw new InvalidDataException("The room must retain its sofa and work area.");
        }

        public static Bounds GeometryBounds(Renderer renderer)
        {
            Mesh mesh = renderer.GetComponent<MeshFilter>()?.sharedMesh;
            if (mesh == null || mesh.vertexCount == 0) throw new InvalidDataException("Missing mesh geometry: " + renderer.name);
            Vector3[] vertices = mesh.vertices;
            var bounds = new Bounds(renderer.transform.TransformPoint(vertices[0]), Vector3.zero);
            for (int i = 1; i < vertices.Length; i++) bounds.Encapsulate(renderer.transform.TransformPoint(vertices[i]));
            return bounds;
        }

        private static bool HasBedToken(string value) =>
            value.IndexOf("bed", StringComparison.OrdinalIgnoreCase) >= 0;
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static void RequireNear(float value, float expected, string label)
        {
            if (Mathf.Abs(value - expected) > .012f)
                throw new InvalidDataException($"Unexpected {label}: {value:F4} m, expected {expected:F4} m.");
        }
        private static Shader RequireBakedShader() => Resources.Load<Shader>("CoastalBakedRadiance") ??
            throw new InvalidOperationException("The Coastal V2 room requires its bundled radiance shader.");
    }
}
