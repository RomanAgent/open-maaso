using UnityEditor;
using UnityEngine;

namespace Maaso.World.Editor
{
    public static class WorldDaySkyInstaller
    {
        private const string MaterialPath =
            "Assets/MaasoWorld/Resources/Maaso_DaySky.mat";
        private const string ShaderName = "Maaso/Mobile Day Sky";

        [MenuItem("Maaso/World/Install Bundled Day Sky")]
        public static void Install()
        {
            Shader shader = Shader.Find(ShaderName);
            if (shader == null || !shader.isSupported)
            {
                throw new System.InvalidOperationException(
                    $"Mobile day sky shader is unavailable: {ShaderName}.");
            }

            Material material = AssetDatabase.LoadAssetAtPath<Material>(
                MaterialPath);
            var configured = new Material(shader)
            {
                name = "Maaso_DaySky",
            };
            configured.SetColor("_Tint", Color.white);
            configured.SetFloat("_Exposure", 1f);
            configured.SetColor(
                "_ZenithColor",
                new Color(0.34f, 0.69f, 0.96f, 1f));
            configured.SetColor(
                "_HorizonColor",
                new Color(0.78f, 0.91f, 1f, 1f));

            if (material == null)
            {
                material = configured;
                AssetDatabase.CreateAsset(material, MaterialPath);
            }
            else
            {
                EditorUtility.CopySerialized(configured, material);
                Object.DestroyImmediate(configured);
            }

            EditorUtility.SetDirty(material);
            AssetDatabase.SaveAssets();
        }
    }
}
