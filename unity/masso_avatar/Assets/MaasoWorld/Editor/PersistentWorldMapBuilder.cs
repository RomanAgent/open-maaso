using UnityEditor;
using UnityEngine;

namespace Maaso.World.Editor
{
    public static class PersistentWorldMapBuilder
    {
        private const string PrefabPath =
            "Assets/MaasoWorld/Resources/PersonalSpaceMap.prefab";

        [MenuItem("Maaso/World/Build Personal Space Runtime Map")]
        public static void CreatePersonalSpaceMap()
        {
            EnsureFolder("Assets/MaasoWorld", "Resources");

            var root = new GameObject(PersistentWorldMapController.ResourceName);
            try
            {
                PersistentWorldMapController map =
                    PersistentWorldMapController.BuildDefaultMap(root);
                AttachPersonalSpaceModel(map);
                ApplyWhiteboxGroundMaterial(map);
                PrefabUtility.SaveAsPrefabAsset(root, PrefabPath);
            }
            finally
            {
                Object.DestroyImmediate(root);
            }

            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            Debug.Log($"[MaasoWorld] generated {PrefabPath}");
        }

        private static void ApplyWhiteboxGroundMaterial(
            PersistentWorldMapController map)
        {
            Renderer groundRenderer = map.transform
                .Find("WorldGround")?
                .GetComponent<Renderer>();
            Material material = AssetDatabase.LoadAssetAtPath<Material>(
                PersonalSpaceSceneBuilder.RuntimeMaterialPath);
            if (groundRenderer == null || material == null)
            {
                throw new System.InvalidOperationException(
                    "The whitebox ground and neutral material are required.");
            }
            groundRenderer.sharedMaterial = material;
        }

        private static void AttachPersonalSpaceModel(
            PersistentWorldMapController map)
        {
            GameObject modelAsset = AssetDatabase.LoadAssetAtPath<GameObject>(
                PersonalSpaceSceneBuilder.RuntimeModelPath);
            Material material = AssetDatabase.LoadAssetAtPath<Material>(
                PersonalSpaceSceneBuilder.RuntimeMaterialPath);
            Transform visualRoot = map.transform.Find(
                "PersistentEnvironmentRoot/BaseVisuals/WhiteboxVisuals");
            if (modelAsset == null || material == null || visualRoot == null)
            {
                throw new System.InvalidOperationException(
                    "The authored PersonalSpace room assets are required.");
            }

            for (int index = visualRoot.childCount - 1; index >= 0; index--)
            {
                Object.DestroyImmediate(visualRoot.GetChild(index).gameObject);
            }
            GameObject model = PrefabUtility.InstantiatePrefab(
                modelAsset,
                visualRoot) as GameObject;
            if (model == null)
            {
                throw new System.InvalidOperationException(
                    "Unable to instantiate the PersonalSpace room model.");
            }
            model.name = "PersonalSpaceModel";
            model.transform.SetLocalPositionAndRotation(
                Vector3.zero,
                Quaternion.identity);
            model.transform.localScale = Vector3.one;
            PersonalSpaceSceneBuilder.ConfigureModel(model, material);
        }

        private static void EnsureFolder(string parent, string name)
        {
            string path = $"{parent}/{name}";
            if (!AssetDatabase.IsValidFolder(path))
            {
                AssetDatabase.CreateFolder(parent, name);
            }
        }
    }
}
