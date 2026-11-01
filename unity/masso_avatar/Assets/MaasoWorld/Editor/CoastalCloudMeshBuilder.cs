#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using System.Collections.Generic;

namespace Maaso.World.Editor
{
    /// <summary>Bakes two density/light volumes once. Runtime rendering samples
    /// this shared linear texture inside small, closed proxy boxes.</summary>
    public static class CoastalCloudMeshBuilder
    {
        public const string MeshPath = "Assets/MaasoWorld/Resources/CoastalCloudVolume.asset";
        public const string MaterialPath = "Assets/MaasoWorld/Resources/CoastalCloudVolume.mat";
        public const string DensityPath = "Assets/MaasoWorld/Resources/CoastalCloudDensity.asset";
        public const int VariantWidth = 128, VolumeHeight = 96, VolumeDepth = 80;
        private const int Variants = 2, Padding = 3;
        private static readonly Vector3 SunDirection = new Vector3(-.45f, .82f, .32f).normalized;
        private static readonly Vector3 ReferenceSize = new(14.5f, 10f, 8f);
        private static readonly Quaternion NoiseRotation = Quaternion.Euler(17, 31, 11);
        private static readonly Vector3[][] Centers = {
            new Vector3[] { new(-.32f,-.07f,.01f), new(-.16f,.04f,-.02f), new(.035f,.18f,-.01f),
                new(.22f,.02f,.02f), new(.35f,-.10f,.005f), new(-.01f,-.06f,.025f), new(.08f,.02f,.19f) },
            new Vector3[] { new(-.31f,-.08f,-.015f), new(-.20f,.17f,.015f), new(.015f,.055f,-.09f),
                new(.24f,.10f,.01f), new(.34f,-.09f,-.025f), new(.04f,-.06f,.02f), new(-.07f,-.005f,.18f) },
        };
        private static readonly Vector3[][] Radii = {
            new Vector3[] { new(.15f,.13f,.20f), new(.22f,.19f,.24f), new(.17f,.24f,.24f),
                new(.20f,.17f,.23f), new(.115f,.10f,.16f), new(.34f,.16f,.25f), new(.18f,.16f,.18f) },
            new Vector3[] { new(.16f,.13f,.19f), new(.18f,.23f,.22f), new(.22f,.19f,.24f),
                new(.17f,.21f,.23f), new(.13f,.11f,.17f), new(.32f,.16f,.25f), new(.20f,.15f,.17f) },
        };
        private readonly struct Puff
        {
            public readonly Vector3 Center, Radius;
            public readonly float Weight;
            public Puff(Vector3 center, Vector3 radius, float weight)
            { Center = center; Radius = radius; Weight = weight; }
        }
        private static readonly Puff[][] Shapes = BuildPuffs();

        private static Puff[][] BuildPuffs()
        {
            var result = new Puff[Variants][];
            for (int variant = 0; variant < Variants; variant++)
            {
                var puffs = new List<Puff>();
                for (int i = 0; i < Centers[variant].Length; i++)
                {
                    Vector3 center = Centers[variant][i], radius = Radii[variant][i];
                    puffs.Add(new Puff(center, radius, i == 5 ? .70f : .82f));
                    // The broad base connects the towers. Decorating this flat
                    // ellipsoid creates a row of thin, artificial shelves.
                    if (i == 5) continue;
                    // Broad core plus visible upper/front lobes. A max union
                    // keeps the valleys between them instead of filling them
                    // by summing many overlapping Gaussian densities.
                    for (int lobe = 0; lobe < 12; lobe++)
                    {
                        float y = Mathf.Lerp(-.2f, .95f,
                            (lobe + Hash(i, lobe, variant + 41)) / 12f);
                        float angle = lobe * 2.399963f + i * 1.17f + variant * 2.1f;
                        float rim = Mathf.Sqrt(1f - y * y);
                        var direction = new Vector3(Mathf.Cos(angle) * rim, y, Mathf.Sin(angle) * rim);
                        if (lobe % 4 != 0) direction.z = Mathf.Abs(direction.z);
                        // Round in world space, including the wide hero cloud:
                        // scaling the parent ellipsoid made the lobes pancakes.
                        float size = Mathf.Lerp(.55f, .95f, Hash(i,lobe,variant + 9));
                        var smallRadius = new Vector3(size / ReferenceSize.x,
                            size / ReferenceSize.y, size / ReferenceSize.z);
                        puffs.Add(new Puff(center + Vector3.Scale(radius,direction) * .68f,
                            smallRadius, Mathf.Lerp(.82f,1f,Hash(i,lobe,variant + 27))));
                    }
                }
                result[variant] = puffs.ToArray();
            }
            return result;
        }

        public static void Install(CoastalWindowAtmosphere atmosphere)
        {
            if (atmosphere == null) throw new System.ArgumentNullException(nameof(atmosphere));
            var shader = Shader.Find("Maaso/Coastal Cloud Volume");
            if (shader == null) throw new System.InvalidOperationException("Cloud shader is missing.");
            var mesh = AssetDatabase.LoadAssetAtPath<Mesh>(MeshPath);
            var rebuiltMesh = BuildMesh();
            if (mesh == null) { mesh = rebuiltMesh; AssetDatabase.CreateAsset(mesh, MeshPath); }
            else { EditorUtility.CopySerialized(rebuiltMesh, mesh); Object.DestroyImmediate(rebuiltMesh); }

            var density = AssetDatabase.LoadAssetAtPath<Texture3D>(DensityPath);
            var rebuiltDensity = BuildDensityTexture();
            if (density == null) { density = rebuiltDensity; AssetDatabase.CreateAsset(density, DensityPath); }
            else { EditorUtility.CopySerialized(rebuiltDensity, density); Object.DestroyImmediate(rebuiltDensity); }
            // Tests keep their transient bake readable; the published shared
            // asset discards its CPU copy after upload.
            density.Apply(false, true);

            var material = AssetDatabase.LoadAssetAtPath<Material>(MaterialPath);
            if (material == null)
            {
                material = new Material(shader) { name = "CoastalCloudVolume" };
                AssetDatabase.CreateAsset(material, MaterialPath);
            }
            material.shader = shader;
            material.enableInstancing = true;
            material.SetTexture("_DensityVolume", density);
            material.SetVector("_VolumeResolution", new Vector4(VariantWidth, VolumeHeight, VolumeDepth, Variants));
            material.SetFloat("_Extinction", 1.8f);
            material.SetFloat("_StepCount", 48f);
            material.SetColor("_SunColor", new Color(.98f, .96f, .92f, 1));
            material.SetColor("_ShadowColor", new Color(.46f, .55f, .66f, 1));
            EditorUtility.SetDirty(mesh);
            EditorUtility.SetDirty(density);
            EditorUtility.SetDirty(material);
            atmosphere.Configure(mesh, material);
            EditorUtility.SetDirty(atmosphere);
        }

        public static Mesh BuildMesh()
        {
            var mesh = new Mesh { name = "CoastalCloudVolume" };
            mesh.vertices = new Vector3[] {
                new Vector3(-.5f,-.5f,-.5f), new(.5f,-.5f,-.5f), new(.5f,.5f,-.5f), new(-.5f,.5f,-.5f),
                new Vector3(-.5f,-.5f,.5f), new(.5f,-.5f,.5f), new(.5f,.5f,.5f), new(-.5f,.5f,.5f),
            };
            mesh.triangles = new[] {
                0,2,1, 0,3,2, 4,5,6, 4,6,7,
                0,4,7, 0,7,3, 1,2,6, 1,6,5,
                0,1,5, 0,5,4, 3,7,6, 3,6,2,
            };
            mesh.RecalculateNormals();
            mesh.RecalculateBounds();
            return mesh;
        }

        /// <summary>R=density, G=daylight transmittance, B=sky access, A=height.
        /// Two padded volumes occupy adjacent X regions; no runtime noise bake.</summary>
        public static Texture3D BuildDensityTexture()
        {
            int width = VariantWidth * Variants;
            var values = new float[width * VolumeHeight * VolumeDepth];
            int Index(int variant, int x, int y, int z) => (z * VolumeHeight + y) * width + variant * VariantWidth + x;
            for (int variant = 0; variant < Variants; variant++)
            for (int z = Padding; z < VolumeDepth - Padding; z++)
            for (int y = Padding; y < VolumeHeight - Padding; y++)
            for (int x = Padding; x < VariantWidth - Padding; x++)
            {
                var p = new Vector3(x / (VariantWidth - 1f) - .5f,
                    y / (VolumeHeight - 1f) - .5f, z / (VolumeDepth - 1f) - .5f);
                values[Index(variant, x, y, z)] = Density(p, variant);
            }

            float Sample(int variant, Vector3 p)
            {
                Vector3 uv = p + Vector3.one * .5f;
                if (uv.x <= 0 || uv.y <= 0 || uv.z <= 0 || uv.x >= 1 || uv.y >= 1 || uv.z >= 1) return 0;
                float fx = uv.x * (VariantWidth - 1), fy = uv.y * (VolumeHeight - 1), fz = uv.z * (VolumeDepth - 1);
                int x = Mathf.FloorToInt(fx), y = Mathf.FloorToInt(fy), z = Mathf.FloorToInt(fz);
                fx -= x; fy -= y; fz -= z;
                float a = Mathf.Lerp(values[Index(variant,x,y,z)], values[Index(variant,x+1,y,z)], fx);
                float b = Mathf.Lerp(values[Index(variant,x,y+1,z)], values[Index(variant,x+1,y+1,z)], fx);
                float c = Mathf.Lerp(values[Index(variant,x,y,z+1)], values[Index(variant,x+1,y,z+1)], fx);
                float d = Mathf.Lerp(values[Index(variant,x,y+1,z+1)], values[Index(variant,x+1,y+1,z+1)], fx);
                return Mathf.Lerp(Mathf.Lerp(a,b,fy), Mathf.Lerp(c,d,fy), fz);
            }

            var pixels = new Color32[values.Length];
            var sunStep = new Vector3(SunDirection.x / ReferenceSize.x,
                SunDirection.y / ReferenceSize.y, SunDirection.z / ReferenceSize.z) * .12f;
            for (int variant = 0; variant < Variants; variant++)
            for (int z = 0; z < VolumeDepth; z++)
            for (int y = 0; y < VolumeHeight; y++)
            for (int x = 0; x < VariantWidth; x++)
            {
                int index = Index(variant,x,y,z);
                float density = values[index];
                if (density <= 0) { pixels[index] = new Color32(0,255,255,0); continue; }
                var p = new Vector3(x / (VariantWidth - 1f) - .5f,
                    y / (VolumeHeight - 1f) - .5f, z / (VolumeDepth - 1f) - .5f);
                float sunDepth = 0, skyDepth = 0;
                // Integrate at approximately one voxel per sample; a coarser
                // lighting bake aliases the newly eroded surface into bands.
                for (int step = 0; step < 80; step++) sunDepth += Sample(variant, p + sunStep * (step + .5f)) * .12f;
                for (int step = 0; step < 64; step++) skyDepth += Sample(variant, p + Vector3.up * ((step + .5f) * .0125f)) * (ReferenceSize.y * .0125f);
                pixels[index] = new Color(density, Mathf.Exp(-sunDepth * 1.05f),
                    Mathf.Exp(-skyDepth * .5f), Mathf.Clamp01(p.y + .5f));
            }
            var texture = new Texture3D(width, VolumeHeight, VolumeDepth,
                GraphicsFormat.R8G8B8A8_UNorm, TextureCreationFlags.None)
            {
                name = "CoastalCloudDensity",
                wrapMode = TextureWrapMode.Clamp,
                filterMode = FilterMode.Bilinear,
                anisoLevel = 0,
            };
            texture.SetPixels32(pixels);
            texture.Apply(false, false);
            return texture;
        }

        private static float Density(Vector3 p, int variant)
        {
            float seed = variant * 17.73f;
            // World-space detail stays round under the non-uniform proxy scale.
            // Rotate the noise domain so its lattice does not align with the box.
            Vector3 world = NoiseRotation * Vector3.Scale(p, ReferenceSize);
            var warp = new Vector3(Fractal(world * .65f + Vector3.one * seed),
                Fractal(world * .65f + new Vector3(13,7,seed)),
                Fractal(world * .65f + new Vector3(seed,23,5))) - Vector3.one * .5f;
            Vector3 q = p + new Vector3(warp.x / ReferenceSize.x,
                warp.y / ReferenceSize.y, warp.z / ReferenceSize.z) * 1.8f;
            float macro = 0;
            foreach (Puff puff in Shapes[variant])
            {
                Vector3 d = q - puff.Center, r = puff.Radius;
                float distance = d.x*d.x/(r.x*r.x) + d.y*d.y/(r.y*r.y) + d.z*d.z/(r.z*r.z);
                if (distance < 1.3f)
                    macro = Mathf.Max(macro, Mathf.Exp(-2f * distance) * puff.Weight);
            }
            if (macro < .18f) return 0;
            // Cellular erosion breaks the broad puff envelope into billowing
            // lobes. Its bounded threshold leaves dense cores connected, while
            // the rebaked light field shadows the resulting surface valleys.
            float cellular = Cellular(world * 1.2f + Vector3.one * seed);
            float detail = Noise(world * 3.4f + new Vector3(seed,31,7));
            float threshold = .18f + cellular * .24f + (1f - detail) * .06f;
            // Cumulus has a relatively dense core with a narrow, vaporous
            // transition. A broad linear falloff looks like a blurred fog bank.
            float density = Mathf.Clamp01((macro - threshold) * 8f);
            float bottom = Mathf.SmoothStep(0, 1, Mathf.InverseLerp(-.29f,-.19f,p.y));
            float edge = Mathf.Max(Mathf.Abs(p.x), Mathf.Max(Mathf.Abs(p.y), Mathf.Abs(p.z)));
            float padding = 1f - Mathf.SmoothStep(0, 1, Mathf.InverseLerp(.39f,.445f,edge));
            return density * bottom * padding;
        }

        private static float Fractal(Vector3 p) =>
            Noise(p) * .57f + Noise(p * 2.03f + Vector3.one * 9.1f) * .29f + Noise(p * 4.01f + Vector3.one * 2.7f) * .14f;

        private static float Noise(Vector3 p)
        {
            int x = Mathf.FloorToInt(p.x), y = Mathf.FloorToInt(p.y), z = Mathf.FloorToInt(p.z);
            float dx = p.x-x, dy = p.y-y, dz = p.z-z;
            float sx=Fade(dx),sy=Fade(dy),sz=Fade(dz);
            float value = Mathf.Lerp(
                Mathf.Lerp(Mathf.Lerp(Gradient(x,y,z,dx,dy,dz),Gradient(x+1,y,z,dx-1,dy,dz),sx),
                    Mathf.Lerp(Gradient(x,y+1,z,dx,dy-1,dz),Gradient(x+1,y+1,z,dx-1,dy-1,dz),sx),sy),
                Mathf.Lerp(Mathf.Lerp(Gradient(x,y,z+1,dx,dy,dz-1),Gradient(x+1,y,z+1,dx-1,dy,dz-1),sx),
                    Mathf.Lerp(Gradient(x,y+1,z+1,dx,dy-1,dz-1),Gradient(x+1,y+1,z+1,dx-1,dy-1,dz-1),sx),sy),sz);
            return Mathf.Clamp01(.5f + value * .5f);
        }

        private static float Fade(float t) => t*t*t*(t*(t*6-15)+10);

        private static float Gradient(int x, int y, int z, float dx, float dy, float dz)
        {
            int h = Mathf.Min(15, (int)(Hash(x,y,z) * 16));
            float u=h<8?dx:dy, v=h<4?dy:(h==12||h==14?dx:dz);
            return ((h&1)==0?u:-u) + ((h&2)==0?v:-v);
        }

        private static float Cellular(Vector3 p)
        {
            int x=Mathf.FloorToInt(p.x),y=Mathf.FloorToInt(p.y),z=Mathf.FloorToInt(p.z);
            float nearest=4;
            for(int dz=-1;dz<=1;dz++) for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++)
            {
                int cx=x+dx,cy=y+dy,cz=z+dz;
                var feature=new Vector3(cx+Hash(cx,cy,cz), cy+Hash(cx+97,cy+13,cz+7),
                    cz+Hash(cx+29,cy+53,cz+131));
                nearest=Mathf.Min(nearest,(p-feature).sqrMagnitude);
            }
            return Mathf.Clamp01(Mathf.Sqrt(nearest));
        }

        private static float Hash(int x, int y, int z)
        {
            unchecked
            {
                uint h = (uint)x * 374761393u + (uint)y * 668265263u + (uint)z * 2147483647u;
                h = (h ^ (h >> 13)) * 1274126177u;
                return ((h ^ (h >> 16)) & 0x00ffffffu) / 16777215f;
            }
        }
    }
}
#endif
