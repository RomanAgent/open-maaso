using System.Collections.Generic;
using Maaso.World;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.Avatar
{
    /// <summary>
    /// A far-field portrait effect for the built-in renderer. The whole avatar
    /// remains sharp; an explicit silhouette also protects transparent MToon
    /// hair and clothes that do not contribute to CameraDepthTexture.
    /// </summary>
    [DisallowMultipleComponent]
    [ExecuteAlways]
    [RequireComponent(typeof(Camera))]
    public sealed class PortraitDepthOfField : MonoBehaviour
    {
        public const string ShaderResourceName = "MaasoPortraitDepthOfField";

        [SerializeField] private Transform focusTarget;
        [SerializeField, Min(0f)] private float subjectClearance = 0.35f;
        [SerializeField, Min(0.1f)] private float backgroundTransition = 2.2f;
        [SerializeField, Range(0f, 8f)] private float blurRadius = 4.5f;

        private readonly List<Renderer> renderers = new();
        private readonly List<Material> sharedMaterials = new();
        private readonly Dictionary<Material, Material> silhouetteMaterials = new();
        private Camera targetCamera;
        private FrontFullBodyCamera framing;
        private Material effectMaterial;
        private CommandBuffer silhouetteCommands;
        private Transform previousTarget;

        public Transform FocusTarget
        {
            get => focusTarget;
            set => focusTarget = value;
        }

        public float FocusDistance { get; private set; }
        public float BackgroundStartDistance { get; private set; }
        public bool HasFocus { get; private set; }

        // A world overview disables FrontFullBodyCamera. Transparent portal and
        // desktop-pet cameras must preserve their original RGBA presentation.
        public bool CanRender => TryGetRenderStrength(out _);
        public float RenderStrength => TryGetRenderStrength(out float strength) ? strength : 0f;

        private bool TryGetRenderStrength(out float strength)
        {
            strength = 0f;
            if (!enabled || !HasFocus || targetCamera == null || targetCamera.orthographic ||
                (targetCamera.clearFlags != CameraClearFlags.Skybox && targetCamera.backgroundColor.a < .99f))
                return false;
            if (framing == null || framing.enabled) { strength = 1f; return true; }
            // Only this same local room/leased actor can fade its existing Home
            // portrait while the room owns framing. Generic overview, inactive
            // rooms and other renderers retain the original bypass.
            WorldCameraDirector world = GetComponent<WorldCameraDirector>();
            Transform target = focusTarget != null ? focusTarget : framing.TargetRoot;
            return world != null && world.TryGetPrivatePortraitStrength(target, out strength);
        }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
            Camera camera = Camera.main;
            if (camera != null &&
                camera.GetComponent<FrontFullBodyCamera>() != null &&
                camera.GetComponent<PortraitDepthOfField>() == null)
            {
                camera.gameObject.AddComponent<PortraitDepthOfField>();
            }
        }

        private void OnEnable()
        {
            targetCamera = GetComponent<Camera>();
            framing = GetComponent<FrontFullBodyCamera>();
            targetCamera.depthTextureMode |= DepthTextureMode.Depth;
        }

        private void OnPreCull()
        {
            UpdateFocus();
            if (CanRender)
            {
                targetCamera.depthTextureMode |= DepthTextureMode.Depth;
            }
        }

        public bool UpdateFocus()
        {
            targetCamera ??= GetComponent<Camera>();
            framing = GetComponent<FrontFullBodyCamera>();
            Transform target = focusTarget != null ? focusTarget : framing?.TargetRoot;
            HasFocus = false;
            FocusDistance = 0f;
            BackgroundStartDistance = 0f;
            renderers.Clear();
            if (target != previousTarget)
            {
                ReleaseSilhouetteMaterials();
                previousTarget = target;
            }
            if (target == null || targetCamera == null)
            {
                return false;
            }

            target.GetComponentsInChildren(false, renderers);
            Bounds bounds = default;
            bool found = false;
            foreach (Renderer renderer in renderers)
            {
                if (!renderer.enabled || renderer.forceRenderingOff ||
                    renderer is ParticleSystemRenderer || renderer is TrailRenderer ||
                    renderer is LineRenderer)
                {
                    continue;
                }
                Bounds item = renderer.bounds;
                if (!IsFinite(item.center) || !IsFinite(item.extents))
                {
                    continue;
                }
                if (!found)
                {
                    bounds = item;
                    found = true;
                }
                else
                {
                    bounds.Encapsulate(item);
                }
            }
            if (!found)
            {
                return false;
            }

            FocusDistance = Vector3.Dot(
                bounds.center - targetCamera.transform.position,
                targetCamera.transform.forward);
            if (FocusDistance <= targetCamera.nearClipPlane)
            {
                return false;
            }
            BackgroundStartDistance = CalculateBackgroundStartDistance(
                targetCamera, bounds, subjectClearance);
            HasFocus = true;
            return true;
        }

        public static float CalculateBackgroundStartDistance(
            Camera camera, Bounds subjectBounds, float clearance)
        {
            Vector3 forward = camera.transform.forward;
            Vector3 extents = subjectBounds.extents;
            float centerDepth = Vector3.Dot(
                subjectBounds.center - camera.transform.position, forward);
            float depthRadius = Mathf.Abs(forward.x) * extents.x +
                Mathf.Abs(forward.y) * extents.y + Mathf.Abs(forward.z) * extents.z;
            return Mathf.Max(camera.nearClipPlane,
                centerDepth + depthRadius + Mathf.Max(0f, clearance));
        }

        public static float CalculateBlurWeight(
            float sceneDepth, float backgroundStart, float transitionDistance)
        {
            if (float.IsNaN(sceneDepth) || float.IsNaN(backgroundStart))
            {
                return 0f;
            }
            float progress = Mathf.Clamp01(
                (sceneDepth - backgroundStart) / Mathf.Max(0.1f, transitionDistance));
            return progress * progress * (3f - 2f * progress);
        }

        private void OnRenderImage(RenderTexture source, RenderTexture destination)
        {
            if (!UpdateFocus() || !CanRender || RenderStrength <= 0f || blurRadius <= 0f ||
                GraphicsSettings.currentRenderPipeline != null ||
                !EnsureMaterial())
            {
                Graphics.Blit(source, destination);
                return;
            }

            // Half-resolution separable blur bounds the mobile cost. The final
            // composite samples the original full-resolution image for the body.
            int width = Mathf.Max(1, source.width / 2);
            int height = Mathf.Max(1, source.height / 2);
            RenderTexture near = null;
            RenderTexture far = null;
            RenderTexture silhouette = null;
            try
            {
                RenderTextureFormat blurFormat = SystemInfo.SupportsRenderTextureFormat(
                    RenderTextureFormat.ARGBHalf)
                    ? RenderTextureFormat.ARGBHalf : RenderTextureFormat.ARGB32;
                near = RenderTexture.GetTemporary(width, height, 0, blurFormat);
                far = RenderTexture.GetTemporary(width, height, 0, blurFormat);
                silhouette = RenderTexture.GetTemporary(source.width, source.height,
                    0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
                near.filterMode = far.filterMode = FilterMode.Bilinear;
                silhouette.filterMode = FilterMode.Bilinear;
                near.wrapMode = far.wrapMode = silhouette.wrapMode = TextureWrapMode.Clamp;

                DrawSilhouette(silhouette);
                effectMaterial.SetTexture("_SubjectMask", silhouette);
                effectMaterial.SetFloat("_BackgroundStart", BackgroundStartDistance);
                effectMaterial.SetFloat("_BackgroundTransition", backgroundTransition);
                effectMaterial.SetFloat("_PortraitStrength", RenderStrength);
                ConfigureBlurKernel();
                Graphics.Blit(source, near, effectMaterial, 0);
                effectMaterial.SetVector("_BlurDirection",
                    new Vector4(1f / width, 0f, 0f, 0f));
                Graphics.Blit(near, far, effectMaterial, 1);
                effectMaterial.SetVector("_BlurDirection",
                    new Vector4(0f, 1f / height, 0f, 0f));
                Graphics.Blit(far, near, effectMaterial, 1);
                effectMaterial.SetTexture("_BlurredBackground", near);
                Graphics.Blit(source, destination, effectMaterial, 2);
            }
            finally
            {
                if (near != null) RenderTexture.ReleaseTemporary(near);
                if (far != null) RenderTexture.ReleaseTemporary(far);
                if (silhouette != null) RenderTexture.ReleaseTemporary(silhouette);
            }
        }

        private void ConfigureBlurKernel()
        {
            // Thirteen adjacent texels avoid the repeated edges caused by
            // stretching optimized bilinear taps farther than one texel apart.
            float sigma = Mathf.Max(0.5f, blurRadius * 0.5f);
            Vector4 weightsA = Vector4.zero;
            Vector4 weightsB = Vector4.zero;
            float sum = 0f;
            for (int index = 0; index <= 6; index++)
            {
                float weight = Mathf.Exp(-(index * index) / (2f * sigma * sigma));
                if (index < 4) weightsA[index] = weight;
                else weightsB[index - 4] = weight;
                sum += weight * (index == 0 ? 1f : 2f);
            }
            effectMaterial.SetVector("_BlurWeightsA", weightsA / sum);
            effectMaterial.SetVector("_BlurWeightsB", weightsB / sum);
        }

        private bool EnsureMaterial()
        {
            if (effectMaterial != null)
            {
                return true;
            }
            Shader shader = Resources.Load<Shader>(ShaderResourceName);
            if (shader == null || !shader.isSupported)
            {
                return false;
            }
            effectMaterial = new Material(shader) { hideFlags = HideFlags.HideAndDontSave };
            silhouetteCommands = new CommandBuffer { name = "Maaso portrait subject silhouette" };
            return true;
        }

        private void DrawSilhouette(RenderTexture target)
        {
            silhouetteCommands.Clear();
            silhouetteCommands.SetRenderTarget(target);
            silhouetteCommands.ClearRenderTarget(false, true, Color.clear);
            silhouetteCommands.SetViewProjectionMatrices(
                targetCamera.worldToCameraMatrix,
                // Built-in command buffers perform the render-target conversion.
                // Passing an already converted GPU matrix flips the mask twice
                // on Metal and protects the mirrored location of a hair card.
                targetCamera.projectionMatrix);
            foreach (Renderer renderer in renderers)
            {
                if (renderer == null || !renderer.enabled || renderer.forceRenderingOff ||
                    !renderer.gameObject.activeInHierarchy ||
                    (targetCamera.cullingMask & (1 << renderer.gameObject.layer)) == 0 ||
                    renderer is not MeshRenderer && renderer is not SkinnedMeshRenderer)
                {
                    continue;
                }
                sharedMaterials.Clear();
                renderer.GetSharedMaterials(sharedMaterials);
                for (int index = 0; index < sharedMaterials.Count; index++)
                {
                    Material source = sharedMaterials[index];
                    if (source == null) continue;
                    if (!silhouetteMaterials.TryGetValue(source, out Material mask))
                    {
                        mask = new Material(effectMaterial.shader)
                        {
                            hideFlags = HideFlags.HideAndDontSave,
                        };
                        silhouetteMaterials.Add(source, mask);
                    }
                    bool alphaTest = source.IsKeywordEnabled("_ALPHATEST_ON") ||
                        source.GetTag("RenderType", false) == "TransparentCutout";
                    bool hasAlpha = source.renderQueue >= 2450 || alphaTest;
                    mask.SetFloat("_MaskCutoff", alphaTest && source.HasProperty("_Cutoff")
                        ? source.GetFloat("_Cutoff") : 0.02f);
                    string colorProperty = source.HasProperty("_BaseColorFactor")
                        ? "_BaseColorFactor" : source.HasProperty("_BaseColor")
                            ? "_BaseColor" : "_Color";
                    float opacity = hasAlpha && source.HasProperty(colorProperty)
                        ? source.GetColor(colorProperty).a : 1f;
                    mask.SetFloat("_MaskOpacity", opacity);
                    string textureProperty = source.HasProperty("_BaseMap")
                        ? "_BaseMap" : "_MainTex";
                    Texture texture = hasAlpha && source.HasProperty(textureProperty)
                        ? source.GetTexture(textureProperty) : null;
                    mask.SetTexture("_MaskMainTex", texture != null ? texture : Texture2D.whiteTexture);
                    if (texture != null)
                    {
                        mask.SetTextureScale("_MaskMainTex", source.GetTextureScale(textureProperty));
                        mask.SetTextureOffset("_MaskMainTex", source.GetTextureOffset(textureProperty));
                    }
                    else
                    {
                        mask.SetTextureScale("_MaskMainTex", Vector2.one);
                        mask.SetTextureOffset("_MaskMainTex", Vector2.zero);
                    }
                    silhouetteCommands.DrawRenderer(renderer, mask, index, 3);
                }
            }
            Graphics.ExecuteCommandBuffer(silhouetteCommands);
        }

        private void OnDisable()
        {
            HasFocus = false;
            ReleaseSilhouetteMaterials();
            if (effectMaterial != null)
            {
                DestroyOwnedMaterial(effectMaterial);
                effectMaterial = null;
            }
            silhouetteCommands?.Release();
            silhouetteCommands = null;
            // Other systems may also request Depth, so do not clear their flag.
        }

        private void ReleaseSilhouetteMaterials()
        {
            foreach (Material material in silhouetteMaterials.Values)
            {
                DestroyOwnedMaterial(material);
            }
            silhouetteMaterials.Clear();
        }

        private static void DestroyOwnedMaterial(Material material)
        {
            if (Application.isPlaying) Destroy(material);
            else DestroyImmediate(material);
        }

        private static bool IsFinite(Vector3 value) =>
            float.IsFinite(value.x) && float.IsFinite(value.y) && float.IsFinite(value.z);
    }
}
