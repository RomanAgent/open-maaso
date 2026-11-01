using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    public static class MaasoModularAnimeInstaller
    {
        private const string FemaleSourcePath =
            "Assets/Rukha93/ModularAnimeCharacter/Prefabs/F_FullBody.prefab";
        private const string FemaleTopPath =
            "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/" +
            "F_top.010_shirtandtie.fbx";
        private const string FemaleBottomPath =
            "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/" +
            "F_bot.004_skinnyjeans.fbx";
        private const string ShoesPath =
            "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/" +
            "F_shoes.006_lowsneakers.fbx";
        private const string FemaleHairPath =
            "Assets/Rukha93/ModularAnimeCharacter/Prefabs/HairStyles/" +
            "C_hair_medium.001.prefab";
        private const string ControllerPath =
            "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private const string RuntimeShaderName =
            "Maaso/Avatar/Modular Anime Mask Lit";
        private const string BundleSourceDirectory =
            "Assets/MaasoAvatar/AvatarBundleSources/ModularAnime";
        private const string FemaleTargetPath =
            BundleSourceDirectory + "/Female.prefab";

        [MenuItem("Maaso/Avatar/Install Modular Anime Female")]
        public static void Install()
        {
            RuntimeAnimatorController controller =
                AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                    ControllerPath);
            if (controller == null)
            {
                throw new InvalidOperationException(
                    "Maaso Humanoid controller is missing: " + ControllerPath);
            }
            Shader runtimeShader = Shader.Find(RuntimeShaderName);
            if (runtimeShader == null)
            {
                throw new InvalidOperationException(
                    "Modular Anime runtime shader is missing: " +
                    RuntimeShaderName);
            }

            Directory.CreateDirectory(BundleSourceDirectory);
            InstallPrefab(
                FemaleSourcePath,
                FemaleTargetPath,
                "Modular Anime Female",
                controller,
                runtimeShader,
                "Female",
                FemaleHairPath,
                FemaleTopPath,
                FemaleBottomPath);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            Debug.Log(
                "[MaasoAvatar] Installed Modular Anime Female runtime prefab.");
        }

        private static void InstallPrefab(
            string sourcePath,
            string targetPath,
            string displayName,
            RuntimeAnimatorController controller,
            Shader runtimeShader,
            string materialGroup,
            string hairPath,
            string topPath,
            string bottomPath)
        {
            GameObject source = AssetDatabase.LoadAssetAtPath<GameObject>(sourcePath);
            if (source == null)
            {
                throw new InvalidOperationException(
                    "Modular Anime source prefab is missing: " + sourcePath);
            }

            GameObject instance =
                PrefabUtility.InstantiatePrefab(source) as GameObject;
            if (instance == null)
            {
                throw new InvalidOperationException(
                    "Could not instantiate Modular Anime source prefab: " +
                    sourcePath);
            }

            try
            {
                instance.name = displayName;
                Animator animator = instance.GetComponentInChildren<Animator>(true);
                if (animator == null ||
                    animator.avatar == null ||
                    !animator.avatar.isHuman)
                {
                    throw new InvalidOperationException(
                        "Modular Anime prefab must contain a valid Humanoid Animator: " +
                        sourcePath);
                }

                animator.runtimeAnimatorController = controller;
                animator.applyRootMotion = false;
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;

                SkinnedMeshRenderer reference =
                    FindReferenceBodyRenderer(instance);
                AttachClothing(instance, reference, topPath, "Top10");
                AttachClothing(instance, reference, bottomPath, "Bot4");
                AttachClothing(instance, reference, ShoesPath, "Shoes6");
                HideCoveredBodyMeshes(instance);
                AttachHair(instance, animator, hairPath);

                SkinnedMeshRenderer[] renderers =
                    instance.GetComponentsInChildren<SkinnedMeshRenderer>(true);
                if (renderers.Length == 0)
                {
                    throw new InvalidOperationException(
                        "Modular Anime prefab does not contain skinned meshes: " +
                        sourcePath);
                }

                for (int index = 0; index < renderers.Length; index++)
                {
                    renderers[index].updateWhenOffscreen = true;
                }
                ConvertShaderGraphMaterials(
                    instance,
                    runtimeShader,
                    materialGroup);

                GameObject saved = PrefabUtility.SaveAsPrefabAsset(
                    instance,
                    targetPath,
                    out bool success);
                if (!success || saved == null)
                {
                    throw new InvalidOperationException(
                        "Could not save Modular Anime runtime prefab: " +
                        targetPath);
                }
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(instance);
            }
        }

        private static SkinnedMeshRenderer FindReferenceBodyRenderer(
            GameObject instance)
        {
            SkinnedMeshRenderer[] renderers =
                instance.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            SkinnedMeshRenderer reference = null;
            for (int index = 0; index < renderers.Length; index++)
            {
                if (renderers[index].name.IndexOf(
                        "_body_",
                        StringComparison.OrdinalIgnoreCase) < 0)
                {
                    continue;
                }
                if (reference == null ||
                    renderers[index].bones.Length > reference.bones.Length)
                {
                    reference = renderers[index];
                }
            }
            if (reference == null)
            {
                throw new InvalidOperationException(
                    "Modular Anime body does not provide a reference skin.");
            }
            return reference;
        }

        private static void HideCoveredBodyMeshes(GameObject instance)
        {
            // Mirrors the vendor customization metadata exactly:
            // Top.10 hides body parts 1, 2, 3, 20, 21; Bot.04 hides
            // 0, 30, 32; Shoes.06 hides none. In particular, feet must stay
            // visible to bridge the skinny-jean cuffs into the low sneakers.
            string[] coveredSuffixes =
            {
                "_body_torso",
                "_body_torso.001",
                "_body_shoulders",
                "_body_arms_upper",
                "_body_arms_lower",
                "_body_hips",
                "_body_legs_upper",
                "_body_legs_lower",
            };
            SkinnedMeshRenderer[] renderers =
                instance.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            for (int index = 0; index < renderers.Length; index++)
            {
                for (int suffixIndex = 0;
                     suffixIndex < coveredSuffixes.Length;
                     suffixIndex++)
                {
                    if (!renderers[index].name.EndsWith(
                            coveredSuffixes[suffixIndex],
                            StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    UnityEngine.Object.DestroyImmediate(
                        renderers[index].gameObject);
                    break;
                }
            }
        }

        private static void AttachClothing(
            GameObject instance,
            SkinnedMeshRenderer reference,
            string assetPath,
            string objectName)
        {
            GameObject clothingAsset =
                AssetDatabase.LoadAssetAtPath<GameObject>(assetPath);
            SkinnedMeshRenderer source = clothingAsset == null
                ? null
                : clothingAsset.GetComponentInChildren<SkinnedMeshRenderer>(true);
            if (source == null || source.sharedMesh == null)
            {
                throw new InvalidOperationException(
                    "Modular Anime clothing mesh is missing: " + assetPath);
            }

            GameObject clothing = new GameObject(objectName);
            clothing.transform.SetParent(instance.transform, false);
            SkinnedMeshRenderer renderer =
                clothing.AddComponent<SkinnedMeshRenderer>();
            renderer.rootBone = reference.rootBone;
            renderer.bones = reference.bones;
            renderer.localBounds = source.localBounds;
            renderer.sharedMesh = source.sharedMesh;
            renderer.sharedMaterials = source.sharedMaterials;
            renderer.updateWhenOffscreen = true;
        }

        private static void AttachHair(
            GameObject instance,
            Animator animator,
            string hairPath)
        {
            GameObject hairPrefab =
                AssetDatabase.LoadAssetAtPath<GameObject>(hairPath);
            if (hairPrefab == null)
            {
                throw new InvalidOperationException(
                    "Modular Anime hair prefab is missing: " + hairPath);
            }

            Transform head = animator.GetBoneTransform(HumanBodyBones.Head);
            if (head == null)
            {
                throw new InvalidOperationException(
                    "Modular Anime Humanoid is missing its Head bone: " +
                    instance.name);
            }

            GameObject hair =
                PrefabUtility.InstantiatePrefab(hairPrefab, head) as GameObject;
            if (hair == null)
            {
                throw new InvalidOperationException(
                    "Could not instantiate Modular Anime hair: " + hairPath);
            }
            hair.transform.SetLocalPositionAndRotation(
                hairPrefab.transform.localPosition,
                hairPrefab.transform.localRotation);
            hair.transform.localScale = hairPrefab.transform.localScale;
        }

        private static void ConvertShaderGraphMaterials(
            GameObject instance,
            Shader runtimeShader,
            string materialGroup)
        {
            string materialDirectory =
                BundleSourceDirectory + "/Materials/" + materialGroup;
            Directory.CreateDirectory(materialDirectory);
            Dictionary<Material, Material> converted =
                new Dictionary<Material, Material>();
            HashSet<string> usedMaterialPaths = new HashSet<string>();
            Renderer[] renderers =
                instance.GetComponentsInChildren<Renderer>(true);
            for (int rendererIndex = 0;
                 rendererIndex < renderers.Length;
                 rendererIndex++)
            {
                Material[] materials = renderers[rendererIndex].sharedMaterials;
                for (int materialIndex = 0;
                     materialIndex < materials.Length;
                     materialIndex++)
                {
                    Material material = materials[materialIndex];
                    if (material == null)
                    {
                        continue;
                    }
                    if (converted.TryGetValue(
                            material,
                            out Material convertedMaterial))
                    {
                        materials[materialIndex] = convertedMaterial;
                        continue;
                    }

                    string shaderPath = material.shader == null
                        ? string.Empty
                        : AssetDatabase.GetAssetPath(material.shader);
                    bool isBroken =
                        material.shader == null ||
                        material.shader.name == "Hidden/InternalErrorShader";
                    bool isShaderGraph = shaderPath.EndsWith(
                        ".shadergraph",
                        StringComparison.OrdinalIgnoreCase);
                    if (!isBroken && !isShaderGraph)
                    {
                        continue;
                    }

                    Material runtimeMaterial = new Material(material)
                    {
                        name = material.name,
                        shader = runtimeShader,
                    };
                    runtimeMaterial.SetFloat(
                        "_UseMask",
                        runtimeMaterial.GetTexture("_BaseMap") == null ? 0f : 1f);

                    string materialPath =
                        materialDirectory + "/" + material.name + ".mat";
                    usedMaterialPaths.Add(materialPath);
                    Material existing =
                        AssetDatabase.LoadAssetAtPath<Material>(materialPath);
                    if (existing == null)
                    {
                        AssetDatabase.CreateAsset(runtimeMaterial, materialPath);
                        convertedMaterial = runtimeMaterial;
                    }
                    else
                    {
                        EditorUtility.CopySerialized(runtimeMaterial, existing);
                        UnityEngine.Object.DestroyImmediate(runtimeMaterial);
                        EditorUtility.SetDirty(existing);
                        convertedMaterial = existing;
                    }

                    converted[material] = convertedMaterial;
                    materials[materialIndex] = convertedMaterial;
                }
                renderers[rendererIndex].sharedMaterials = materials;
            }
            PruneUnusedRuntimeMaterials(
                materialDirectory,
                usedMaterialPaths);
        }

        private static void PruneUnusedRuntimeMaterials(
            string materialDirectory,
            HashSet<string> usedMaterialPaths)
        {
            string[] materialGuids = AssetDatabase.FindAssets(
                "t:Material",
                new[] { materialDirectory });
            for (int index = 0; index < materialGuids.Length; index++)
            {
                string path =
                    AssetDatabase.GUIDToAssetPath(materialGuids[index]);
                if (!usedMaterialPaths.Contains(path))
                {
                    AssetDatabase.DeleteAsset(path);
                }
            }
        }
    }
}
