using System;
using System.Collections.Generic;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar
{
    /// <summary>
    /// Pupil-only presentation for the inspected Matt eye textures. The source
    /// Standard materials, eye geometry and transparent cornea remain immutable.
    /// Zero returns the exact original material references, not a neutral lookalike.
    /// </summary>
    public sealed class AvatarPupilMaterialAdapter : IDisposable
    {
        public const string ShaderResource = "MattPupilStandard";
        public const string ShaderName = "Maaso/Avatar/Matt Pupil Standard";
        public const string DiameterProperty = "_MaasoPupilDiameter";
        private static readonly int DiameterId = Shader.PropertyToID(DiameterProperty);
        private static readonly int UvId = Shader.PropertyToID("_MaasoPupilUv");
        // The original 1024px source has its pupil at UV .5/.5, radius about
        // .045, and the outer iris rim at .125. Stop inside that fixed rim.
        private static readonly Vector4 SourceUv = new(.5f, .5f, .118f, .045f);
        private readonly List<Material> scratch = new(4);
        private readonly List<Binding> bindings = new(4);
        private SkinnedMeshRenderer eye;
        private bool attached;
        public bool IsBound => eye != null && bindings.Count > 0;
        public int BoundMaterialCount => bindings.Count;
        private readonly struct Binding
        {
            public readonly int Slot;
            public readonly Material Original, Instance;
            public Binding(int slot, Material original, Material instance)
            { Slot = slot; Original = original; Instance = instance; }
        }

        public bool Bind(Transform root)
        {
            Dispose();
            if (root == null) return false;
            var source = root.GetComponentInChildren<AvatarHumanoidSourceIdlePose>(true);
            if (source == null || !source.IsCaptured) return false;
            foreach (var renderer in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                if (renderer.name != "CC_Base_Eye" || renderer.sharedMesh == null ||
                    renderer.sharedMesh.blendShapeCount != 0) continue;
                renderer.GetSharedMaterials(scratch);
                // The master lists four material slots, but all 640 eye faces
                // use Std_Eye_R. Unity correctly exports one shared slot for
                // BOTH eyes. Inspect used slots, never infer two from names.
                if (scratch.Count == 0 || scratch.Count > 4 || !scratch.Exists(IsSourceEye)) continue;
                Shader shader = Resources.Load<Shader>(ShaderResource);
                if (shader == null || !shader.isSupported) return false;
                eye = renderer;
                for (int slot = 0; slot < scratch.Count; slot++)
                {
                    Material original = scratch[slot];
                    if (!IsSourceEye(original)) continue;
                    // Clone once per used inner-eye slot at binding. Never call
                    // renderer.materials or allocate in the expression frame.
                    var clone = new Material(original)
                    {
                        name = original.name + " (Pupil Presentation)",
                        hideFlags = HideFlags.DontSave,
                        shader = shader,
                    };
                    clone.CopyPropertiesFromMaterial(original);
                    clone.SetFloat(DiameterId, 1f);
                    clone.SetVector(UvId, SourceUv);
                    bindings.Add(new Binding(slot, original, clone));
                }
                return true;
            }
            return false;
        }

        /// <summary>-1 = subtle contraction, 0 = exact source, +1 = 16% dilation.
        /// The emotion driver normally uses only the calibrated positive range.</summary>
        public void ApplyNormalized(float dilation)
        {
            if (!IsBound) return;
            if (float.IsNaN(dilation) || float.IsInfinity(dilation)) dilation = 0f;
            dilation = Mathf.Clamp(dilation, -1f, 1f);
            if (Mathf.Abs(dilation) < .000001f) { Reset(); return; }
            if (!attached)
            {
                eye.GetSharedMaterials(scratch);
                foreach (Binding binding in bindings)
                    if (binding.Slot >= scratch.Count || scratch[binding.Slot] != binding.Original)
                        return; // A newer material owner wins until the next Bind.
                foreach (Binding binding in bindings) scratch[binding.Slot] = binding.Instance;
                eye.SetSharedMaterials(scratch);
                attached = true;
            }
            float diameter = 1f + dilation * (dilation >= 0f ? .16f : .08f);
            foreach (Binding binding in bindings) binding.Instance.SetFloat(DiameterId, diameter);
        }

        public void Reset()
        {
            if (attached && eye != null)
            {
                eye.GetSharedMaterials(scratch);
                foreach (Binding binding in bindings)
                    if (binding.Slot < scratch.Count && scratch[binding.Slot] == binding.Instance)
                        scratch[binding.Slot] = binding.Original;
                eye.SetSharedMaterials(scratch);
            }
            attached = false;
            foreach (Binding binding in bindings)
                if (binding.Instance != null) binding.Instance.SetFloat(DiameterId, 1f);
        }

        public void Dispose()
        {
            Reset();
            foreach (Binding binding in bindings)
            {
                if (binding.Instance != null)
                {
                    if (Application.isPlaying) Object.Destroy(binding.Instance);
                    else Object.DestroyImmediate(binding.Instance);
                }
            }
            eye = null; scratch.Clear(); bindings.Clear();
        }

        private static bool IsSourceEye(Material material)
        {
            return material != null && (material.name == "Std_Eye_L" || material.name == "Std_Eye_R") &&
                material.shader != null && material.shader.name == "Standard" &&
                material.mainTexture != null && material.mainTexture.name == material.name + "_Diffuse" &&
                material.mainTextureScale == Vector2.one && material.mainTextureOffset == Vector2.zero &&
                material.GetFloat("_Mode") == 0f;
        }
    }
}
