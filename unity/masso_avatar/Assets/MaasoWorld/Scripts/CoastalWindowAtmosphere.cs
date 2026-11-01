using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.World
{
    /// <summary>Bounded cloud volumes outside the room. Density and lighting are
    /// baked assets; the phone only drifts six shared proxy-mesh instances.</summary>
    [DisallowMultipleComponent]
    public sealed class CoastalWindowAtmosphere : MonoBehaviour
    {
        [SerializeField] private Mesh cloudMesh;
        [SerializeField] private Material cloudMaterial;
        private static readonly int CloudVariant = Shader.PropertyToID("_CloudVariant");
        private static readonly int DensityMultiplier = Shader.PropertyToID("_DensityMultiplier");
        // The central bank carries the view; smaller side/far banks leave blue
        // sky between them. Bounds are disjoint so transparent object sorting
        // never has to resolve intersecting density volumes.
        private static readonly Vector3[] Centers = {
            new(-9.5f, 11.2f, -31f), new(-17f, 9f, -23f),
            new(12.5f, 8.8f, -25f), new(-26f, 10.8f, -22f),
            new(25.5f, 11.5f, -24f), new(1.5f, 8f, -38f),
        };
        private static readonly Vector3[] Sizes = {
            new(14.5f, 10f, 8f), new(9f, 4.7f, 5.5f),
            new(9f, 4.6f, 5.6f), new(7f, 4f, 4.8f),
            new(7.8f, 4.4f, 5f), new(7.4f, 3.8f, 4.5f),
        };
        private static readonly float[] Densities = { 1f, .92f, 1.04f, .86f, .90f, .85f };
        private Transform clouds;
        private readonly Transform[] volumes = new Transform[Centers.Length];
        public int CloudCount => volumes.Length;
        public Mesh CloudMesh => cloudMesh;
        public Material CloudMaterial => cloudMaterial;

        public void Configure(Mesh mesh, Material material)
        {
            if (cloudMesh != mesh || cloudMaterial != material) Clear();
            cloudMesh = mesh;
            cloudMaterial = material;
        }

        private void OnEnable()
        {
            if (Application.isPlaying) PresentAt(Time.unscaledTime);
        }

        private void Update()
        {
            if (Application.isPlaying) PresentAt(Time.unscaledTime);
        }

        public void PresentAt(float seconds)
        {
            if (!isActiveAndEnabled || cloudMesh == null || cloudMaterial == null ||
                float.IsNaN(seconds) || float.IsInfinity(seconds)) return;
            if (clouds == null)
            {
                var root = new GameObject("CoastalCloudVolumes")
                { hideFlags = HideFlags.DontSave };
                clouds = root.transform;
                clouds.SetParent(transform, false);
                root.layer = gameObject.layer;
                var properties = new MaterialPropertyBlock();
                for (int i = 0; i < volumes.Length; i++)
                {
                    var cloud = new GameObject("CoastalCloud_" + i)
                    { hideFlags = HideFlags.DontSave, layer = gameObject.layer };
                    cloud.transform.SetParent(clouds, false);
                    cloud.AddComponent<MeshFilter>().sharedMesh = cloudMesh;
                    var renderer = cloud.AddComponent<MeshRenderer>();
                    renderer.sharedMaterial = cloudMaterial;
                    renderer.shadowCastingMode = ShadowCastingMode.Off;
                    renderer.receiveShadows = false;
                    renderer.lightProbeUsage = LightProbeUsage.Off;
                    renderer.reflectionProbeUsage = ReflectionProbeUsage.Off;
                    properties.SetFloat(CloudVariant, i % 2);
                    properties.SetFloat(DensityMultiplier, Densities[i]);
                    renderer.SetPropertyBlock(properties);
                    // Do not rotate or mirror the baked directional light.
                    cloud.transform.localRotation = Quaternion.identity;
                    cloud.transform.localScale = Sizes[i];
                    volumes[i] = cloud.transform;
                }
            }
            // One wind offset preserves separation and never wraps/teleports.
            // The density stays attached to each cloud instead of swimming
            // through it, and no material/property-block work runs per frame.
            var drift = new Vector3(
                Mathf.Sin(seconds * .003f) * 1.8f,
                Mathf.Sin(seconds * .0013f) * .08f,
                Mathf.Sin(seconds * .0021f) * .12f);
            for (int i = 0; i < volumes.Length; i++)
            {
                volumes[i].localPosition = Centers[i] + drift;
            }
        }

        private void OnDisable() => Clear();
        private void OnDestroy() => Clear();
        private void Clear()
        {
            if (clouds == null) return;
            var old = clouds.gameObject;
            clouds = null;
            old.SetActive(false);
            if (Application.isPlaying) Destroy(old); else DestroyImmediate(old);
            for (int i = 0; i < volumes.Length; i++) volumes[i] = null;
        }
    }
}
