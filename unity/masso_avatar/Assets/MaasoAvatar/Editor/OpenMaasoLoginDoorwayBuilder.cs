#if UNITY_EDITOR
using System;
using Maaso.World;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Project-owned primitive entrance for the public scene. It uses the
    /// original shared-door/camera contract, without importing room artwork.
    /// </summary>
    public static class OpenMaasoLoginDoorwayBuilder
    {
        public const string Revision = "open-maaso-shared-entry-v1";

        public static PersistentWorldMapController Install()
        {
            var mapRoot = new GameObject(PersistentWorldMapController.ResourceName);
            var map = PersistentWorldMapController.BuildDefaultMap(mapRoot);
            var white = Material("OpenMaasoEntryWhite", new Color(.97f, .975f, .98f), .25f);
            var metal = Material("OpenMaasoEntryHardware", new Color(.19f, .21f, .23f), .75f);
            var mat = Material("OpenMaasoEntryMat", new Color(.49f, .23f, .13f), .03f);
            var ground = map.GroundCollider.GetComponent<Renderer>();
            ground.sharedMaterial = white;
            ground.SetPropertyBlock(null);

            var root = new GameObject("OpenMaasoSharedEntrance");
            root.transform.SetParent(map.PersistentEnvironmentRoot, false);
            // The public scene has no licensed room shell. Its neutral white
            // interior backdrop keeps the default sky out of the Home view.
            Cube("InteriorWhiteBackdrop", root.transform, new Vector3(0, 4, -4.2f), new Vector3(30, 12, .05f), white);
            var rig = root.AddComponent<LoginDoorwayRig>();
            Transform hinge = Anchor("EntryHinge", root.transform, new Vector3(2.985f, 0, 4.035f));
            Transform leaf = Cube("EntryDoorLeaf", hinge, new Vector3(-.485f, 1.175f, 0),
                new Vector3(.97f, 2.35f, .06f), white);
            Transform frame = Anchor("EntryFrame", root.transform, Vector3.zero);
            Cube("FrameLeft", frame, new Vector3(1.965f, 1.19f, 4.1f), new Vector3(.09f, 2.46f, .24f), white);
            Cube("FrameRight", frame, new Vector3(3.035f, 1.19f, 4.1f), new Vector3(.09f, 2.46f, .24f), white);
            Cube("FrameTop", frame, new Vector3(2.5f, 2.415f, 4.1f), new Vector3(1.16f, .09f, .24f), white);
            // Six ordinary raised-panel outlines; all meshes are Unity cubes.
            for (int row = 0; row < 3; row++)
            for (int col = 0; col < 2; col++)
            {
                float x = col == 0 ? -.715f : -.255f;
                float y = .43f + row * .67f;
                foreach (float z in new[] { -.044f, .044f })
                {
                    Cube($"Panel-{row}-{col}-L-{z}", hinge, new Vector3(x - .19f, y, z), new Vector3(.024f, .54f, .02f), white);
                    Cube($"Panel-{row}-{col}-R-{z}", hinge, new Vector3(x + .19f, y, z), new Vector3(.024f, .54f, .02f), white);
                    Cube($"Panel-{row}-{col}-T-{z}", hinge, new Vector3(x, y + .27f, z), new Vector3(.4f, .024f, .02f), white);
                    Cube($"Panel-{row}-{col}-B-{z}", hinge, new Vector3(x, y - .27f, z), new Vector3(.4f, .024f, .02f), white);
                }
            }
            foreach (float z in new[] { -.065f, .065f })
            {
                Cube("DoorHandlePlate", hinge, new Vector3(-.84f, 1.08f, z), new Vector3(.06f, .13f, .025f), metal);
                Cube("DoorHandle", hinge, new Vector3(-.78f, 1.08f, z * 1.5f), new Vector3(.15f, .025f, .025f), metal);
            }
            Cube("EntryApron", root.transform, new Vector3(2.5f, -.025f, 5), new Vector3(3.2f, .05f, 2), white);
            Cube("EntryThreshold", root.transform, new Vector3(2.5f, .012f, 4.02f), new Vector3(1.07f, .024f, .22f), white);
            Cube("ExteriorWallLeft", root.transform, new Vector3(3.57f, 1.6f, 4.225f), new Vector3(1.06f, 3.2f, .05f), white);
            Cube("ExteriorWallRight", root.transform, new Vector3(1.45f, 1.6f, 4.225f), new Vector3(1.02f, 3.2f, .05f), white);
            Cube("ExteriorLintel", root.transform, new Vector3(2.5f, 2.8f, 4.225f), new Vector3(1.08f, .8f, .05f), white);
            Cube("WelcomeMat", root.transform, new Vector3(2.5f, .006f, 4.68f), new Vector3(.94f, .012f, .53f), mat);
            Transform lettering = Anchor("WelcomeMatLettering", root.transform, new Vector3(2.5f, .014f, 4.68f));
            lettering.localRotation = Quaternion.Euler(90, 180, 0);
            var text = lettering.gameObject.AddComponent<TextMesh>();
            text.text = "WELCOME"; text.anchor = TextAnchor.MiddleCenter; text.alignment = TextAlignment.Center;
            text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
            text.fontSize = 48; text.characterSize = .021f; text.color = new Color(.92f, .87f, .72f);
            lettering.GetComponent<MeshRenderer>().sharedMaterial = text.font.material;

            var binding = new LoginDoorwaySceneBinding
            {
                SceneRoot = root.transform, SceneRevision = Revision, EntryId = "main_entry",
                DoorHinge = hinge, DoorLeaf = leaf, FrameRoot = frame,
                ExteriorCamera = Anchor("EntryExteriorCamera", root.transform, new Vector3(2.5f, 1.2f, 5.8f)),
                ThresholdCamera = Anchor("EntryThresholdCamera", root.transform, new Vector3(2.5f, 1.35f, 3.85f)),
                InteriorCamera = Anchor("EntryInteriorCamera", root.transform, new Vector3(1.45f, 1.35f, 2.5f)),
                DoorLookTarget = Anchor("EntryLookTarget", root.transform, new Vector3(2.5f, .25f, 4.03f)),
                LobbyCamera = Anchor("EntryArrivalCamera", root.transform, new Vector3(0, 1.35f, 1.6f)),
                LobbyLookTarget = Anchor("EntryArrivalLook", root.transform, new Vector3(0, 1, 0)),
                EntryWallBounds = new Bounds(new Vector3(0, 1.6f, 4.1f), new Vector3(8, 3.2f, .2f)),
                EntryOpeningBounds = new Bounds(new Vector3(2.5f, 1.185f, 4.1f), new Vector3(1.02f, 2.37f, .2f)),
                // No private room is shipped. Reserve an explicitly authored
                // off-route exclusion volume rather than reuse paid-room data.
                ProtectedRoomBounds = new Bounds(new Vector3(20, 1.6f, 20), new Vector3(1, 3.2f, 1)),
            };
            if (!rig.BindSceneEntry(binding) || LoginDoorwayRig.Ensure(map) != rig)
                throw new InvalidOperationException("The public scene's shared login entry is not usable.");
            Transform fill = Anchor("EntryExteriorFill", root.transform, new Vector3(2.5f, 2.8f, 5.8f));
            fill.LookAt(new Vector3(2.5f, 1.1f, 4.03f));
            var light = fill.gameObject.AddComponent<Light>();
            light.type = LightType.Spot; light.color = Color.white; light.spotAngle = 100;
            light.range = 4; light.intensity = 1.2f; light.shadows = LightShadows.Soft;
            return map;
        }

        private static Transform Anchor(string name, Transform parent, Vector3 position)
        {
            var value = new GameObject(name).transform;
            value.SetParent(parent, false); value.localPosition = position; return value;
        }

        private static Transform Cube(string name, Transform parent, Vector3 position, Vector3 scale, Material material)
        {
            var value = GameObject.CreatePrimitive(PrimitiveType.Cube);
            value.name = name; value.transform.SetParent(parent, false);
            value.transform.localPosition = position; value.transform.localScale = scale;
            Object.DestroyImmediate(value.GetComponent<Collider>());
            value.GetComponent<Renderer>().sharedMaterial = material;
            return value.transform;
        }

        private static Material Material(string name, Color color, float smoothness)
        {
            const string folder = "Assets/MaasoAvatar/Materials";
            string path = folder + "/" + name + ".mat";
            var material = AssetDatabase.LoadAssetAtPath<Material>(path);
            if (material == null)
            {
                material = new Material(Shader.Find("Standard"));
                AssetDatabase.CreateAsset(material, path);
            }
            material.color = color; material.SetFloat("_Glossiness", smoothness);
            EditorUtility.SetDirty(material);
            return material;
        }
    }
}
#endif
