#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Maaso.Avatar;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using Object=UnityEngine.Object;

namespace Maaso.World.Editor
{
    /// <summary>Publishes the separately reviewed V4 room. Missing/staging
    /// assets fail before the active room is saved; V2 art is never a fallback.</summary>
    public static class CoastalRoomV4Importer
    {
        public const string AssetRoot="Assets/MaasoWorld/PersonalSpace/CoastalV4";
        public const string ModelPath=AssetRoot+"/PersonalSpaceV4.fbx";
        public const string ManifestPath=AssetRoot+"/manifest.json";
        public const string RuntimeModelPath="Assets/MaasoWorld/Resources/PersonalSpaceModel.prefab";
        public const string RuntimeMapPath="Assets/MaasoWorld/Resources/PersonalSpaceMap.prefab";
        private const string LegacySourceSha="9fadf0b94ddb4e981a9bb9d952bae742b68dac6f8cbcbf0bc313d7794e8df296";
        private const string LegacyRecipeSha="74e4db2e25aed0cf0aa95acc5f9651ae600f0df438fbac8ea5999db73783e5f2";
        [Serializable] public sealed class MaterialEntry
        { public string name,shading,texture,baseColorTexture,normalTexture,metallicSmoothnessTexture;public float[] baseColor;public float opacity=1,metallic,roughness=.5f;public bool doubleSided; }
        [Serializable] public sealed class MeshEntry
        { public string name,material,movableRoot;public int triangles;public string[] sourceObjectNames;public bool environmentBackdrop,excludeFromFloorPlan; }
        [Serializable] public sealed class DoorEntry
        { public string id,rootNode,leafNode,frameRootNode,kind,initialState;public string[] sharedBy;public float[] closedPositionUnity,openPositionUnity,closedRotationEulerUnity,openRotationEulerUnity,openingBoundsBlender,closedLeafBoundsBlender,closedLeafBoundsUnity; }
        [Serializable] public sealed class AnchorEntry { public string name;public float[] positionBlender,positionUnity; }
        [Serializable] public sealed class RegionEntry { public string id;public float[] boundsBlender,boundsUnity; }
        [Serializable] public sealed class BedColliderEntry { public float[] boundsBlender,boundsUnity,footprintBlender,footprintUnity; }
        [Serializable] public sealed class InteractionPoint { public float[] positionBlender,positionUnity,directionBlender,directionUnity; }
        [Serializable] public sealed class BedInteractions
        { public InteractionPoint lie_center,lie_head_toward,sit_south_edge,sit_south_faces,approach_south,approach_foot,footSouthCorner; }
        [Serializable] public sealed class LockedObject { public string name;public float[] matrixBlender;public string[] materials; }
        public sealed class AtlasLineage
        {
            public string bakeSourceSha256,bakeRecipeSha256,sourceManifestSha256,meshDigestSha256;
            public bool reused;public Dictionary<string,string> textureHashes;
        }
        [Serializable] public sealed class Manifest
        {
            public int schemaVersion,version,bedCount;public float roomSize,roomHeight,mattressTopMetres;
            public string status,axes,sourceSha256,fbxSha256,layoutSha256,bedSha256,walkableRegionRule,recipeSha256;
            public bool colorTransformVerified;
            [NonSerialized] public Dictionary<string,string> artifactHashes;
            [NonSerialized] public Dictionary<string,AtlasLineage> atlasLineage;
            public bool bedContactReviewRequired;public MaterialEntry[] materials;public MeshEntry[] meshes;
            public DoorEntry[] doors;public AnchorEntry[] anchors;public RegionEntry[] walkableRegions;
            public BedColliderEntry bedCollider;public BedInteractions bedInteraction;public LockedObject[] lockedOriginalObjects;
            public string[] bedSourceObjects;
        }
        public static Manifest ParseManifest(string json)
        {
            JObject document;
            try { document=JObject.Parse(json,new JsonLoadSettings { DuplicatePropertyNameHandling=DuplicatePropertyNameHandling.Error }); }
            catch(JsonException error) { throw new InvalidDataException("Invalid V4 manifest JSON.",error); }
            var value=JsonUtility.FromJson<Manifest>(json);
            if(value==null || value.schemaVersion!=4 || value.version!=4 || value.status!="ready_for_unity" ||
                value.axes!="Blender X,Y,Z -> Unity -X,Z,-Y" || value.bedCount!=1 ||
                !Finite(value.roomSize)||!Finite(value.roomHeight)||!Finite(value.mattressTopMetres)||value.mattressTopMetres<.2f||value.mattressTopMetres>1.2f ||
                Mathf.Abs(value.roomSize-8)>.001f || Mathf.Abs(value.roomHeight-3.2f)>.001f ||
                !Hash(value.sourceSha256)||!Hash(value.fbxSha256)||!Hash(value.layoutSha256)||!Hash(value.bedSha256)||!Hash(value.recipeSha256) ||
                !value.colorTransformVerified||document["colorTransformVerified"]?.Type!=JTokenType.Boolean ||
                value.walkableRegionRule!="union_then_dynamic_blockers" || value.bedContactReviewRequired)
                throw new InvalidDataException("V4 requires a complete color-reviewed, ground-contact-reviewed export.");
            if(value.materials==null||value.materials.Length==0||value.meshes==null||value.meshes.Length==0||
                value.doors?.Length!=2||value.anchors==null||value.walkableRegions?.Length!=3||value.lockedOriginalObjects?.Length!=150||
                value.bedSourceObjects?.Length!=50||value.bedInteraction==null||value.bedCollider==null)
                throw new InvalidDataException("V4 export is missing its material/geometry/door/room contract.");
            Unique(value.materials.Select(x=>x?.name),"material");Unique(value.meshes.Select(x=>x?.name),"mesh");
            Unique(value.anchors.Select(x=>x?.name),"anchor");Unique(value.doors.Select(x=>x?.id),"door");
            Unique(value.walkableRegions.Select(x=>x?.id),"walkable region");Unique(value.lockedOriginalObjects.Select(x=>x?.name),"locked source object");
            Unique(value.bedSourceObjects,"bed source object");
            if(!(document["artifactHashes"] is JObject artifactHashes)||!artifactHashes.HasValues)
                throw new InvalidDataException("V4 texture provenance is missing.");
            value.artifactHashes=new Dictionary<string,string>(StringComparer.Ordinal);
            foreach(var artifact in artifactHashes.Properties())
            {
                TexturePath(artifact.Name);
                if(artifact.Value.Type!=JTokenType.String||!Hash((string)artifact.Value))
                    throw new InvalidDataException("Invalid V4 artifact hash.");
                value.artifactHashes.Add(artifact.Name,(string)artifact.Value);
            }
            var materials=value.materials.ToDictionary(x=>x.name,StringComparer.Ordinal);
            var sources=new HashSet<string>(StringComparer.Ordinal);
            foreach(var m in value.materials)
            {
                if((m.shading!="display_baked"&&m.shading!="pbr")||!Finite(m.opacity)||m.opacity<0||m.opacity>1||
                    !Finite(m.metallic)||!Finite(m.roughness)||m.metallic<0||m.metallic>1||m.roughness<0||m.roughness>1)throw new InvalidDataException("Invalid V4 material.");
                if(m.shading=="display_baked") TexturePath(m.texture);
                foreach(string texture in new[]{m.baseColorTexture,m.normalTexture,m.metallicSmoothnessTexture})if(!string.IsNullOrEmpty(texture))TexturePath(texture);
                if(m.baseColor!=null&&(m.baseColor.Length!=4||m.baseColor.Any(x=>!Finite(x))))throw new InvalidDataException("Invalid PBR base color.");
                foreach(string texture in new[]{m.texture,m.baseColorTexture,m.normalTexture,m.metallicSmoothnessTexture})
                    if(!string.IsNullOrEmpty(texture)&&!value.artifactHashes.ContainsKey(texture))
                        throw new InvalidDataException("A referenced V4 texture has no reviewed hash.");
            }
            ValidateAtlasLineage(document,value);
            foreach(var mesh in value.meshes)
            {
                if(mesh.triangles<=0||!materials.ContainsKey(mesh.material??"")||mesh.sourceObjectNames==null||mesh.sourceObjectNames.Length==0||
                    (!string.IsNullOrEmpty(mesh.movableRoot)&&mesh.movableRoot!="V4_EntryHinge"&&mesh.movableRoot!="V4_BedroomDoorSlide"))
                    throw new InvalidDataException("Invalid V4 mesh binding.");
                foreach(string source in mesh.sourceObjectNames)if(string.IsNullOrEmpty(source)||!sources.Add(source))throw new InvalidDataException("Duplicate or empty exported source object.");
                if(mesh.sourceObjectNames.Contains("V4_EntryLeaf")&&mesh.movableRoot!="V4_EntryHinge")throw new InvalidDataException("Entry leaf leaked into the static bake.");
                if(mesh.sourceObjectNames.Contains("V4_BedroomDoorLeaf")&&mesh.movableRoot!="V4_BedroomDoorSlide")throw new InvalidDataException("Bedroom leaf leaked into the static bake.");
            }
            if(sources.Contains("V2_Entrance_Door")||sources.Contains("V2_Entrance_Baked")||!sources.Contains("V4_EntryLeaf")||!sources.Contains("V4_BedroomDoorLeaf"))
                throw new InvalidDataException("The room must contain only its formal shared entry and separate bedroom leaf.");
            foreach(var item in value.lockedOriginalObjects)
                if(item.matrixBlender?.Length!=16||item.matrixBlender.Any(x=>!Finite(x))||!sources.Contains(item.name))throw new InvalidDataException("A locked original object was lost.");
            foreach(string name in value.bedSourceObjects)if(!sources.Contains(name))throw new InvalidDataException("The authored bed is incomplete.");
            foreach(var anchor in value.anchors) {Vector(anchor.positionUnity);Vector(anchor.positionBlender);}
            foreach(var region in value.walkableRegions) Rect(region.boundsUnity);
            foreach(var door in value.doors)
            {
                Vector(door.closedPositionUnity);Vector(door.openPositionUnity);Vector(door.closedRotationEulerUnity);Vector(door.openRotationEulerUnity);BlenderBounds(door.openingBoundsBlender);
                RequireSameBounds(BlenderBounds(door.closedLeafBoundsBlender),Bounds3(door.closedLeafBoundsUnity),.0001f,"Door source axes differ from its closed leaf bounds.");
                if(door.initialState!="closed")throw new InvalidDataException("Door roots must be exported in their declared closed pose.");
            }
            var entry=value.doors.SingleOrDefault(x=>x.id=="entry");var bedroom=value.doors.SingleOrDefault(x=>x.id=="bedroom");
            if(entry?.kind!="hinge"||entry.rootNode!="V4_EntryHinge"||entry.leafNode!="V4_EntryLeaf"||entry.frameRootNode!="V4_EntryFrameRoot"||
                entry.sharedBy==null||!entry.sharedBy.Contains("home")||!entry.sharedBy.Contains("login")||bedroom?.kind!="slide"||bedroom.rootNode!="V4_BedroomDoorSlide"||bedroom.leafNode!="V4_BedroomDoorLeaf")
                throw new InvalidDataException("Incorrect shared-entry or pocket-door identity.");
            if(!value.walkableRegions.Any(x=>x.id=="main")||!value.walkableRegions.Any(x=>x.id=="bedroom")||!value.walkableRegions.Any(x=>x.id=="bedroom_portal"))throw new InvalidDataException("Walkable union is incomplete.");
            ValidateContractBedBounds(value.bedCollider);
            foreach(var point in new[]{value.bedInteraction.lie_center,value.bedInteraction.sit_south_edge,value.bedInteraction.approach_south,value.bedInteraction.approach_foot,value.bedInteraction.footSouthCorner})Vector(point?.positionUnity);
            Vector(value.bedInteraction.lie_head_toward?.directionUnity);Vector(value.bedInteraction.sit_south_faces?.directionUnity);
            return value;
        }
        private static void ValidateAtlasLineage(JObject document,Manifest manifest)
        {
            var raw=document["atlasLineage"] as JObject;
            if(raw==null)
            {
                // Existing published V4 packages predate per-atlas lineage.
                // A changed geometric source must never silently reuse them.
                if(manifest.sourceSha256!=LegacySourceSha||manifest.recipeSha256!=LegacyRecipeSha)
                    throw new InvalidDataException("Changed V4 sources require per-atlas provenance.");
                return;
            }
            if(raw.Properties().Count()!=manifest.materials.Length)
                throw new InvalidDataException("V4 atlas lineage must cover every material exactly once.");
            manifest.atlasLineage=new Dictionary<string,AtlasLineage>(StringComparer.Ordinal);
            foreach(var material in manifest.materials)
            {
                if(raw[material.name] is not JObject item||
                    item["textureHashes"] is not JObject textureHashes||
                    item["reused"]?.Type!=JTokenType.Boolean)
                    throw new InvalidDataException("V4 material lineage is incomplete: "+material.name);
                var entry=new AtlasLineage{
                    bakeSourceSha256=(string)item["bakeSourceSha256"],
                    bakeRecipeSha256=(string)item["bakeRecipeSha256"],
                    sourceManifestSha256=(string)item["sourceManifestSha256"],
                    meshDigestSha256=(string)item["meshDigestSha256"],
                    reused=(bool)item["reused"],
                    textureHashes=new Dictionary<string,string>(StringComparer.Ordinal),
                };
                if(!Hash(entry.bakeSourceSha256)||!Hash(entry.bakeRecipeSha256)||
                    !Hash(entry.meshDigestSha256)||
                    (entry.reused?!Hash(entry.sourceManifestSha256):!string.IsNullOrEmpty(entry.sourceManifestSha256))||
                    (entry.reused?entry.bakeSourceSha256==manifest.sourceSha256:
                        entry.bakeSourceSha256!=manifest.sourceSha256||entry.bakeRecipeSha256!=manifest.recipeSha256))
                    throw new InvalidDataException("V4 atlas source lineage is inconsistent: "+material.name);
                var expected=new HashSet<string>(new[]{material.texture,material.baseColorTexture,
                    material.normalTexture,material.metallicSmoothnessTexture}
                    .Where(path=>!string.IsNullOrEmpty(path)),StringComparer.Ordinal);
                if(textureHashes.Properties().Count()!=expected.Count)
                    throw new InvalidDataException("V4 atlas texture lineage is incomplete: "+material.name);
                foreach(var property in textureHashes.Properties())
                {
                    if(!expected.Contains(property.Name)||property.Value.Type!=JTokenType.String||
                        !Hash((string)property.Value)||manifest.artifactHashes[property.Name]!=(string)property.Value)
                        throw new InvalidDataException("V4 atlas texture hash differs from the package: "+material.name);
                    entry.textureHashes.Add(property.Name,(string)property.Value);
                }
                manifest.atlasLineage.Add(material.name,entry);
            }
            if(raw.Properties().Any(property=>!manifest.atlasLineage.ContainsKey(property.Name)))
                throw new InvalidDataException("Unknown V4 atlas lineage material.");
            foreach(string updated in new[]{"Baked_Floor","Baked_BedroomTrim"})
                if(!manifest.atlasLineage.TryGetValue(updated,out var entry)||entry.reused)
                    throw new InvalidDataException("The moved entry fibres require newly baked Floor and BedroomTrim atlases.");
        }
        [MenuItem("Maaso/World/Publish Reviewed Coastal V4",false,205)]
        public static void Build()
        {
            string manifestFile=ProjectFile(ManifestPath);
            if(!File.Exists(manifestFile))throw new FileNotFoundException("Promote the reviewed V4 export before building.",manifestFile);
            Manifest manifest=ParseManifest(File.ReadAllText(manifestFile));
            if(!File.Exists(ProjectFile(ModelPath))||Digest(ProjectFile(ModelPath))!=manifest.fbxSha256)throw new InvalidDataException("The V4 FBX is missing or changed after review.");
            ValidatePackageFiles(manifest,ProjectFile(AssetRoot));
            AssetDatabase.ImportAsset(ModelPath,ImportAssetOptions.ForceSynchronousImport);
            var importer=AssetImporter.GetAtPath(ModelPath) as ModelImporter;
            if(importer==null)throw new InvalidDataException("V4 FBX has no importer.");
            importer.globalScale=1;importer.useFileScale=true;importer.bakeAxisConversion=true;
            importer.importCameras=false;importer.importLights=false;importer.importAnimation=false;
            importer.materialImportMode=ModelImporterMaterialImportMode.None;importer.importNormals=ModelImporterNormals.Import;importer.SaveAndReimport();
            var asset=AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath);
            if(asset==null)throw new InvalidDataException("V4 model failed to import.");
            GameObject model=Object.Instantiate(asset),mapObject=null;
            try
            {
                model.name="PersonalSpaceModel";model.transform.SetPositionAndRotation(Vector3.zero,Quaternion.identity);model.transform.localScale=Vector3.one;
                Configure(model,manifest);
                // Validate the completed model before touching either active resource.
                mapObject=new GameObject(PersistentWorldMapController.ResourceName);
                var map=PersistentWorldMapController.BuildDefaultMap(mapObject);
                Transform visual=map.PersistentEnvironmentRoot.Find("BaseVisuals/WhiteboxVisuals");
                var mapModel=Object.Instantiate(model,visual,false);mapModel.name="PersonalSpaceModel";
                var nav=mapModel.GetComponent<PersonalSpaceNavigation>();
                var floor=mapModel.transform.Find("V4WalkableFloor").GetComponent<MeshCollider>();
                map.HomeAgentAnchor.position=Find(mapModel,"V4_HomeAvatar").position;
                map.HomeCameraReference.position=Find(mapModel,"V4_HomeCamera").position;
                Vector3 heading=Find(mapModel,"V4_LobbyLookTarget").position-map.HomeCameraReference.position;heading.y=0;
                map.HomeCameraReference.rotation=Quaternion.LookRotation(heading,Vector3.up);
                var oldGround=mapObject.transform.Find("WorldGround");oldGround.GetComponent<Collider>().enabled=false;oldGround.GetComponent<Renderer>().enabled=false;
                map.Configure(map.HomeAgentAnchor,map.HomeCameraReference,map.WorldPlayCenter,map.WorldSpawnAnchors,map.PersistentEnvironmentRoot,map.WorldDecorationRoot,floor);
                if(LoginDoorwayRig.Ensure(map)==null||nav==null)throw new InvalidDataException("The completed V4 map lost its shared entry or navigation.");
                PrefabUtility.SaveAsPrefabAsset(model,RuntimeModelPath);
                PrefabUtility.SaveAsPrefabAsset(mapObject,RuntimeMapPath);
                AssetDatabase.SaveAssets();
                Debug.Log("[CoastalV4] Published reviewed model, union ground, furniture anchors and one shared entry.");
            }
            finally {if(mapObject!=null)Object.DestroyImmediate(mapObject);Object.DestroyImmediate(model);}
        }
        public static void Configure(GameObject model,Manifest manifest)
        {
            AlignEntryMatTufts(model);
            var bindings=ImportMaterials(manifest);
            var entries=manifest.meshes.ToDictionary(x=>x.name,StringComparer.Ordinal);
            var renderers=model.GetComponentsInChildren<MeshRenderer>(true);
            if(renderers.Length!=entries.Count)throw new InvalidDataException("V4 renderer count does not match manifest.");
            int layer=LayerMask.NameToLayer("PersonalSpaceEnvironment");if(layer<0)throw new InvalidDataException("Room layer is unavailable.");
            foreach(Transform child in model.GetComponentsInChildren<Transform>(true))child.gameObject.layer=layer;
            foreach(var collider in model.GetComponentsInChildren<Collider>(true))Object.DestroyImmediate(collider);
            var blockers=new List<Bounds>{Bounds3(manifest.bedCollider.boundsUnity)};
            var bedSources=new HashSet<string>(manifest.bedSourceObjects,StringComparer.Ordinal);
            Bounds bedGeometry=default;bool hasBedGeometry=false;
            foreach(var renderer in renderers)
            {
                if(!entries.TryGetValue(renderer.name,out var entry))throw new InvalidDataException("Unexpected V4 renderer: "+renderer.name);
                Mesh mesh=renderer.GetComponent<MeshFilter>()?.sharedMesh;
                if(mesh==null||mesh.subMeshCount!=1||mesh.triangles.Length/3!=entry.triangles||mesh.uv.Length!=mesh.vertexCount)throw new InvalidDataException("V4 topology or UV mismatch: "+renderer.name);
                if(entry.sourceObjectNames.Any(bedSources.Contains))
                {
                    if(!entry.sourceObjectNames.All(bedSources.Contains))throw new InvalidDataException("Bed geometry was merged with another object.");
                    Bounds geometry=LocalGeometryBounds(model.transform,renderer);
                    if(hasBedGeometry)bedGeometry.Encapsulate(geometry);else {bedGeometry=geometry;hasBedGeometry=true;}
                }
                // The coir geometry shares a bake atlas with the white entry
                // reveal. Grade only its four authored meshes, leaving the
                // reveal and the raised WELCOME lettering untouched.
                renderer.sharedMaterial=renderer.name is "V4_EntryWelcomeMat" or "V4_EntryMatInset" or "V4_EntryMatTufts" or "V4_EntryMatFringe"
                    ? bindings["EntryCoirColorGrade"] : bindings[entry.material];
                bool baked=manifest.materials.Single(x=>x.name==entry.material).shading=="display_baked";
                renderer.shadowCastingMode=baked?ShadowCastingMode.Off:ShadowCastingMode.On;renderer.receiveShadows=true;
                renderer.lightProbeUsage=baked?LightProbeUsage.Off:LightProbeUsage.BlendProbes;
                if(!string.IsNullOrEmpty(entry.movableRoot))
                {
                    if(!renderer.transform.IsChildOf(Find(model,entry.movableRoot)))throw new InvalidDataException("Movable door hierarchy was flattened.");
                    GameObjectUtility.SetStaticEditorFlags(renderer.gameObject,0);
                }
                if(!entry.environmentBackdrop&&!entry.excludeFromFloorPlan&&string.IsNullOrEmpty(entry.movableRoot)&&entry.sourceObjectNames.Any(BlocksFloor))blockers.Add(LocalGeometryBounds(model.transform,renderer));
            }
            if(!hasBedGeometry)throw new InvalidDataException("The authored bed has no imported geometry.");
            ValidateBedGeometry(manifest,bedGeometry);
            foreach(var anchor in manifest.anchors)
                if(Vector3.Distance(model.transform.InverseTransformPoint(Find(model,anchor.name).position),Vector(anchor.positionUnity))>.015f)throw new InvalidDataException("V4 anchor axis/scale mismatch: "+anchor.name);
            var entryDoor=manifest.doors.Single(x=>x.id=="entry");var bedroomDoor=manifest.doors.Single(x=>x.id=="bedroom");
            foreach(var door in manifest.doors)
            {
                Transform node=Find(model,door.rootNode),leaf=Find(model,door.leafNode);
                foreach(Transform part in node.GetComponentsInChildren<Transform>(true))GameObjectUtility.SetStaticEditorFlags(part.gameObject,0);
                if(!leaf.IsChildOf(node))throw new InvalidDataException("Door leaf is not attached to its pivot.");
                ValidateDoorPose(model.transform,node,door.closedPositionUnity,door.closedRotationEulerUnity);
                var leafRenderer=leaf.GetComponent<MeshRenderer>();
                if(leafRenderer==null)throw new InvalidDataException("Door leaf has no geometry.");
                Bounds aperture=BlenderBounds(door.openingBoundsBlender);
                Bounds leafGeometry=LocalGeometryBounds(model.transform,leafRenderer);
                ValidateDoorGeometry(leafGeometry,aperture,door.kind);
                ValidateClosedLeafBounds(leafGeometry,door.closedLeafBoundsBlender,door.closedLeafBoundsUnity);
                Bounds attachmentEnvelope=aperture;attachmentEnvelope.Expand(.3f);
                var parts=node.GetComponentsInChildren<MeshRenderer>(true).AsEnumerable();
                if(!string.IsNullOrEmpty(door.frameRootNode))parts=parts.Concat(Find(model,door.frameRootNode).GetComponentsInChildren<MeshRenderer>(true));
                foreach(var part in parts)
                {
                    Bounds geometry=LocalGeometryBounds(model.transform,part);
                    if(!attachmentEnvelope.Contains(geometry.min)||!attachmentEnvelope.Contains(geometry.max))
                        throw new InvalidDataException("Door attachment geometry escaped its source aperture: "+part.name);
                }
            }
            var rig=model.AddComponent<LoginDoorwayRig>();
            var opening=BlenderBounds(entryDoor.openingBoundsBlender);
            var wall=new Bounds(new Vector3(0,1.6f,4.1f),new Vector3(8,3.2f,.2f));
            if(opening.min.z>wall.min.z+.002f||opening.max.z<wall.max.z-.002f)throw new InvalidDataException("Entry opening must cover the full wall depth.");
            var bedroomRect=Rect(manifest.walkableRegions.Single(x=>x.id=="bedroom").boundsUnity);
            bedroomRect.center=new Vector3(bedroomRect.center.x,1.6f,bedroomRect.center.z);bedroomRect.size=new Vector3(bedroomRect.size.x,3.2f,bedroomRect.size.z);
            if(!rig.BindSceneEntry(new LoginDoorwaySceneBinding {
                SceneRoot=model.transform,SceneRevision=manifest.sourceSha256,EntryId="main_entry",
                DoorHinge=Find(model,entryDoor.rootNode),DoorLeaf=Find(model,entryDoor.leafNode),FrameRoot=Find(model,entryDoor.frameRootNode),
                ClosedLocalRotation=Quaternion.Euler(Vector(entryDoor.closedRotationEulerUnity)),DoorOpenDegrees=Vector(entryDoor.openRotationEulerUnity).y-Vector(entryDoor.closedRotationEulerUnity).y,
                ExteriorCamera=Find(model,"V4_EntryExteriorCamera"),ThresholdCamera=Find(model,"V4_EntryThresholdCamera"),InteriorCamera=Find(model,"V4_EntryHallCamera"),DoorLookTarget=Find(model,"V4_EntryLookTarget"),
                LobbyCamera=Find(model,"V4_EntryArrivalCamera"),LobbyLookTarget=Find(model,"V4_LobbyLookTarget"),EntryWallBounds=wall,EntryOpeningBounds=opening,ProtectedRoomBounds=bedroomRect,
            }))throw new InvalidDataException("V4 shared entry binding or lobby route is invalid.");
            var navigation=model.AddComponent<PersonalSpaceNavigation>();navigation.Revision=manifest.sourceSha256;
            navigation.WalkableRegions=manifest.walkableRegions.Select(x=>Rect(x.boundsUnity)).ToArray();navigation.Obstacles=blockers.ToArray();
            var footprint=Rect(manifest.bedCollider.footprintUnity);
            navigation.LayoutRevision=CoastalPrivateWorldContract.LayoutRevision;navigation.LayoutDigest=CoastalPrivateWorldContract.LayoutDigest;
            navigation.ContractBedBounds=new WorldMapPlayableBounds{minX=footprint.min.x,maxX=footprint.max.x,minZ=footprint.min.z,maxZ=footprint.max.z};
            navigation.BedroomPortal=BlenderBounds(bedroomDoor.openingBoundsBlender);
            var pocket=model.AddComponent<PersonalSpacePocketDoor>();pocket.SlidingRoot=Find(model,bedroomDoor.rootNode);
            pocket.ClosedLocalPosition=Vector(bedroomDoor.closedPositionUnity);pocket.OpenLocalPosition=Vector(bedroomDoor.openPositionUnity);
            if(!pocket.Ready)throw new InvalidDataException("V4 pocket door is not operational.");navigation.BedroomDoor=pocket;
            if(!CoastalPrivateWorldContract.ValidateNavigation(navigation))throw new InvalidDataException("V4 geometry differs from the fixed private-world navigation identity.");
            AddFurniture(model,manifest,navigation);
            BuildGround(model,navigation.WalkableRegions);
            CoastalWindowBackdropBuilder.Install(model);
            CoastalCloudMeshBuilder.Install(model.AddComponent<CoastalWindowAtmosphere>());
        }
        // The reviewed V4 FBX has one legacy coir mesh baked at the Home
        // origin while the mat, inset, fringe and lettering are at the exterior
        // landing. Correct only that measured export defect; a future FBX
        // rebuilt from the fixed Blender source will already be aligned.
        private static void AlignEntryMatTufts(GameObject model)
        {
            var mat=Find(model,"V4_EntryWelcomeMat").GetComponent<MeshRenderer>();
            var tufts=Find(model,"V4_EntryMatTufts").GetComponent<MeshRenderer>();
            if(mat==null||tufts==null)throw new InvalidDataException("The V4 exterior mat lost its coir geometry.");
            Vector3 matCenter=mat.bounds.center,tuftCenter=tufts.bounds.center;
            if(Vector2.Distance(new Vector2(matCenter.x,matCenter.z),new Vector2(2.5f,4.64f))>.15f)
                throw new InvalidDataException("The V4 welcome mat escaped the exterior landing.");
            var horizontalOffset=new Vector2(matCenter.x-tuftCenter.x,matCenter.z-tuftCenter.z);
            if(horizontalOffset.magnitude>.01f)
            {
                if(Vector2.Distance(new Vector2(tuftCenter.x,tuftCenter.z),new Vector2(.29816f,.59298f))>.025f)
                    throw new InvalidDataException("The V4 mat tufts are at an unreviewed location.");
                tufts.transform.position+=new Vector3(horizontalOffset.x,0,horizontalOffset.y);
            }
            var result=tufts.bounds.center;
            if(Vector2.Distance(new Vector2(matCenter.x,matCenter.z),new Vector2(result.x,result.z))>.01f)
                throw new InvalidDataException("The V4 mat tufts are not on the exterior mat.");
        }
        /// <summary>Checks bytes before importing or saving any active resource.
        /// The supplied directory is the promoted package, never a URL.</summary>
        public static void ValidatePackageFiles(Manifest manifest,string directory)
        {
            if(manifest?.artifactHashes==null||manifest.artifactHashes.Count==0)
                throw new InvalidDataException("V4 artifact provenance is missing.");
            foreach(var artifact in manifest.artifactHashes)
            {
                TexturePath(artifact.Key);
                string path=Path.Combine(directory,artifact.Key);
                if(!File.Exists(path)||Digest(path)!=artifact.Value)
                    throw new InvalidDataException("V4 artifact bytes changed after review: "+artifact.Key);
            }
        }
        private static void ValidateContractBedBounds(BedColliderEntry bed)
        {
            if(bed==null)throw new InvalidDataException("V4 bed collision contract is missing.");
            Bounds bounds=Bounds3(bed.boundsUnity),footprint=Rect(bed.footprintUnity);
            var contract=new WorldMapPlayableBounds {minX=footprint.min.x,maxX=footprint.max.x,minZ=footprint.min.z,maxZ=footprint.max.z};
            if(!CoastalPrivateWorldContract.Exact(CoastalPrivateWorldContract.Bed,contract)||
                Mathf.Abs(bounds.min.x-footprint.min.x)>.0001f||Mathf.Abs(bounds.max.x-footprint.max.x)>.0001f||
                Mathf.Abs(bounds.min.z-footprint.min.z)>.0001f||Mathf.Abs(bounds.max.z-footprint.max.z)>.0001f)
                throw new InvalidDataException("V4 bed collider differs from its fixed navigation footprint.");
            RequireSameBounds(bounds,BlenderBounds(bed.boundsBlender),.0001f,"Bed source axes differ from runtime collision bounds.");
        }
        public static void ValidateBedGeometry(Manifest manifest,Bounds geometry)
        {
            ValidateContractBedBounds(manifest.bedCollider);
            RequireSameBounds(Bounds3(manifest.bedCollider.boundsUnity),geometry,.015f,
                "Imported V4 bed geometry differs from its measured collider.");
        }
        private static void RequireSameBounds(Bounds expected,Bounds actual,float tolerance,string message)
        {
            if(!Finite(actual.min.x)||!Finite(actual.min.y)||!Finite(actual.min.z)||
                !Finite(actual.max.x)||!Finite(actual.max.y)||!Finite(actual.max.z)||
                Vector3.Distance(expected.min,actual.min)>tolerance||Vector3.Distance(expected.max,actual.max)>tolerance)
                throw new InvalidDataException(message);
        }
        public static void ValidateDoorPose(Transform model,Transform pivot,float[] position,float[] rotation)
        {
            if(model==null||pivot==null||
                Vector3.Distance(model.InverseTransformPoint(pivot.position),Vector(position))>.015f||
                Quaternion.Angle(Quaternion.Inverse(model.rotation)*pivot.rotation,Quaternion.Euler(Vector(rotation)))>.5f)
                throw new InvalidDataException("Door closed pivot pose does not match its source contract.");
        }

        public static void ValidateDoorGeometry(Bounds geometry,Bounds opening,string kind)
        {
            Bounds tolerance=opening;tolerance.Expand(.06f);
            float width=kind=="hinge"?geometry.size.x:geometry.size.z;
            float openingWidth=kind=="hinge"?opening.size.x:opening.size.z;
            if((kind!="hinge"&&kind!="slide")||!tolerance.Contains(geometry.min)||!tolerance.Contains(geometry.max)||
                geometry.size.y<opening.size.y*.8f||width<openingWidth*.8f)
                throw new InvalidDataException("Door mesh must fill its closed aperture in room coordinates; a correct pivot alone is insufficient.");
        }

        public static void ValidateClosedLeafBounds(Bounds geometry,float[] blender,float[] unity)
        {
            Bounds expected=Bounds3(unity);
            RequireSameBounds(expected,BlenderBounds(blender),.0001f,"Door closed leaf coordinate conversion is inconsistent.");
            RequireSameBounds(expected,geometry,.002f,"Actual closed door mesh differs from its measured source bounds.");
        }
        private static void AddFurniture(GameObject model,Manifest manifest,PersonalSpaceNavigation navigation)
        {
            Transform root=model.transform;
            var hub=Find(model,"V4_HomeAvatar");
            var sofa=Seat(root,"sofa",new Vector3(-2.77f,.60f,-1.48f),Vector3.right,new Vector3(-2.02f,0,-1.48f));
            var chair=Seat(root,"chair",new Vector3(2.42f,.54f,-2.62f),new Vector3(-1,0,1),new Vector3(1.75f,0,-1.60f));
            var desk=Seat(root,"desk",new Vector3(-2.65f,.53f,2.24f),Vector3.forward,new Vector3(-2.07f,0,2.24f));
            desk.WorkSurface=Point(root,"V4_RuntimeDeskWork",new Vector3(-2.65f,.84f,2.9f),Vector3.forward);
            var data=manifest.bedInteraction;
            var bed=Seat(root,"bed",Vector(data.sit_south_edge.positionUnity),Vector(data.sit_south_faces.directionUnity),Vector(data.approach_south.positionUnity));
            bed.CanLie=true;bed.Lying=Point(root,"V4_RuntimeBedLie",Vector(data.lie_center.positionUnity),-Vector(data.lie_head_toward.directionUnity));
            var nodes=new List<Transform>{hub,Find(model,"V4_BedroomDoorApproach"),Find(model,"V4_BedroomDoorInside"),Find(model,"V4_BedApproach"),
                Point(root,"V4_RuntimeBedFootSouth",Vector(data.footSouthCorner.positionUnity),Vector3.forward),
                Point(root,"V4_RuntimeSofaAisle",new Vector3(-.35f,0,-2.65f),Vector3.forward),
                Point(root,"V4_RuntimeSofaCorridor",new Vector3(-2.02f,0,-2.65f),Vector3.forward),
                Point(root,"V4_RuntimeChairAisle",new Vector3(.5f,0,-1.2f),Vector3.forward),
                Point(root,"V4_RuntimeDeskAisle",new Vector3(-1.4f,0,1.5f),Vector3.forward)};
            var furniture=model.AddComponent<AvatarFurnitureRig>();furniture.SceneKey="coastal_v4";furniture.Navigation=navigation;
            furniture.Anchors=new[]{sofa,chair,desk,bed};navigation.RouteNodes=nodes.ToArray();
            foreach(var anchor in furniture.Anchors)
            {
                if(!navigation.TryBuildRoute(hub.position,anchor.Approach.position,anchor.Waypoints,out _))throw new InvalidDataException("No collision-safe V4 approach to "+anchor.Id);
                string[] surfaces=anchor.Id switch {"sofa"=>new[]{"V4_Sofa_Baked"},"chair"=>new[]{"V4_Lounge_Baked"},"desk"=>new[]{"V4_WorkChair_Baked"},_=>new[]{"V4_BedMattress_Baked","V4_BedBedding_Baked","V4_BedPillows_Baked"}};
                anchor.SeatSupportY=MeasureSupportY(model,surfaces,anchor.Seat.position,anchor.Seat.position.y+.25f);
                anchor.FootFloorY=MeasureSupportY(model,new[]{"V4_Floor_Baked","V4_Rug_Baked","V4_BedroomFloor_Baked"},anchor.Seat.position+anchor.Seat.forward*.4f,.2f);
                if(anchor.CanLie)anchor.LyingSupportY=MeasureSupportY(model,surfaces,anchor.Lying.position,anchor.Lying.position.y+.25f);
                anchor.HasMeasuredSupport=true;
            }
        }
        private static float MeasureSupportY(GameObject model,string[] names,Vector3 at,float maximum)
        {
            float best=float.NegativeInfinity;
            foreach(var renderer in model.GetComponentsInChildren<MeshRenderer>().Where(r=>names.Contains(r.name)))
            {
                var mesh=renderer.GetComponent<MeshFilter>().sharedMesh;var vertices=mesh.vertices;var triangles=mesh.triangles;
                for(int i=0;i<triangles.Length;i+=3)
                {
                    Vector3 a=renderer.transform.TransformPoint(vertices[triangles[i]]),b=renderer.transform.TransformPoint(vertices[triangles[i+1]]),c=renderer.transform.TransformPoint(vertices[triangles[i+2]]);
                    float denominator=(b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z);if(Mathf.Abs(denominator)<1e-8f)continue;
                    float u=((b.z-c.z)*(at.x-c.x)+(c.x-b.x)*(at.z-c.z))/denominator,v=((c.z-a.z)*(at.x-c.x)+(a.x-c.x)*(at.z-c.z))/denominator;
                    if(u<0||v<0||u+v>1)continue;float y=u*a.y+v*b.y+(1-u-v)*c.y;
                    if(y<=maximum&&y>best)best=y;
                }
            }
            if(!Finite(best))throw new InvalidDataException("Furniture support surface is missing at "+at);
            return best;
        }
        private static AvatarFurnitureAnchor Seat(Transform root,string id,Vector3 seat,Vector3 direction,Vector3 approach)=>new() {
            Id=id,Seat=Point(root,"V4_RuntimeSeat_"+id,seat,direction),Approach=Point(root,"V4_RuntimeApproach_"+id,approach,direction),Waypoints=Array.Empty<Transform>(),
        };
        private static Transform Point(Transform root,string name,Vector3 position,Vector3 direction)
        {var child=new GameObject(name);child.transform.SetParent(root,false);child.transform.localPosition=position;child.transform.localRotation=Quaternion.LookRotation(direction.normalized,Vector3.up);return child.transform;}
        private static void BuildGround(GameObject model,IReadOnlyList<Bounds> regions)
        {
            var vertices=new List<Vector3>();var triangles=new List<int>();
            foreach(var r in regions){int start=vertices.Count;vertices.AddRange(new[]{new Vector3(r.min.x,0,r.min.z),new Vector3(r.min.x,0,r.max.z),new Vector3(r.max.x,0,r.max.z),new Vector3(r.max.x,0,r.min.z)});triangles.AddRange(new[]{start,start+1,start+2,start,start+2,start+3});}
            var mesh=new Mesh{name="CoastalV4WalkableUnion"};mesh.SetVertices(vertices);mesh.SetTriangles(triangles,0);mesh.RecalculateBounds();
            string path=AssetRoot+"/WalkableUnion.asset";var existing=AssetDatabase.LoadAssetAtPath<Mesh>(path);
            if(existing==null)AssetDatabase.CreateAsset(mesh,path);else{EditorUtility.CopySerialized(mesh,existing);Object.DestroyImmediate(mesh);mesh=existing;}
            var floor=new GameObject("V4WalkableFloor");floor.transform.SetParent(model.transform,false);floor.AddComponent<MeshCollider>().sharedMesh=mesh;
        }
        private static Dictionary<string,Material> ImportMaterials(Manifest manifest)
        {
            string folder=AssetRoot+"/Materials";if(!AssetDatabase.IsValidFolder(folder))AssetDatabase.CreateFolder(AssetRoot,"Materials");
            var result=new Dictionary<string,Material>(StringComparer.Ordinal);
            foreach(var entry in manifest.materials)
            {
                string path=folder+"/"+SafeName(entry.name)+".mat";var material=AssetDatabase.LoadAssetAtPath<Material>(path);
                Shader shader=Shader.Find(entry.shading=="display_baked"?"Maaso/CoastalBakedRadiance":"Standard");if(shader==null)throw new InvalidDataException("V4 material shader is missing.");
                if(material==null){material=new Material(shader){name=entry.name};AssetDatabase.CreateAsset(material,path);}else material.shader=shader;
                if(entry.shading=="display_baked")
                {
                    CoastalRoomV2Importer.ApplyBakedMaterial(material,Texture(entry.texture),entry.opacity);
                    material.SetFloat("_DynamicShadowStrength",.8f);
                }
                else
                {
                    var c=entry.baseColor??new[]{1f,1f,1f,1f};material.color=new Color(c[0],c[1],c[2],c[3]*entry.opacity);
                    material.SetFloat("_Metallic",Mathf.Clamp01(entry.metallic));material.SetFloat("_Glossiness",1-Mathf.Clamp01(entry.roughness));
                    if(entry.name.EndsWith("_V4_WhiteDoorPaint",StringComparison.Ordinal))
                    {
                        // The authored white paint has a soft emission lift.
                        // PBR export stores its base color but Standard room
                        // lighting otherwise renders the closed login door gray.
                        material.SetColor("_EmissionColor",new Color(.15f,.15f,.15f));
                        material.EnableKeyword("_EMISSION");
                        material.color=new Color(c[0]*1.25f,c[1]*1.25f,c[2]*1.25f,c[3]*entry.opacity);
                    }
                    else
                    {
                        material.SetColor("_EmissionColor",Color.black);
                        material.DisableKeyword("_EMISSION");
                    }
                    if(!string.IsNullOrEmpty(entry.baseColorTexture))material.mainTexture=Texture(entry.baseColorTexture);
                    if(!string.IsNullOrEmpty(entry.normalTexture)){material.SetTexture("_BumpMap",Texture(entry.normalTexture,true));material.EnableKeyword("_NORMALMAP");}
                    if(!string.IsNullOrEmpty(entry.metallicSmoothnessTexture)){material.SetTexture("_MetallicGlossMap",Texture(entry.metallicSmoothnessTexture,false,true));material.EnableKeyword("_METALLICGLOSSMAP");}
                    bool transparent=entry.opacity<.999f||c[3]<.999f;material.SetFloat("_Mode",transparent?2:0);
                    material.SetInt("_SrcBlend",(int)(transparent?BlendMode.SrcAlpha:BlendMode.One));material.SetInt("_DstBlend",(int)(transparent?BlendMode.OneMinusSrcAlpha:BlendMode.Zero));material.SetInt("_ZWrite",transparent?0:1);
                    if(transparent)material.EnableKeyword("_ALPHABLEND_ON");else material.DisableKeyword("_ALPHABLEND_ON");material.renderQueue=transparent?3000:-1;
                }
                material.doubleSidedGI=entry.doubleSided;EditorUtility.SetDirty(material);result.Add(entry.name,material);
            }
            if(!result.TryGetValue("Baked_BedroomTrim",out var entryTrim))
                throw new InvalidDataException("Reviewed entry trim bake is missing.");
            string coirPath=folder+"/EntryCoirColorGrade.mat";
            var coir=AssetDatabase.LoadAssetAtPath<Material>(coirPath);
            if(coir==null){coir=new Material(entryTrim){name="EntryCoirColorGrade"};AssetDatabase.CreateAsset(coir,coirPath);}
            else coir.CopyPropertiesFromMaterial(entryTrim);
            coir.SetColor("_EmissionColor",new Color(.76f,.52f,.28f,1f));
            EditorUtility.SetDirty(coir);
            result.Add("EntryCoirColorGrade",coir);
            return result;
        }
        private static Texture2D Texture(string relative,bool normal=false,bool linear=false)
        {
            string path=TexturePath(relative);AssetDatabase.ImportAsset(path,ImportAssetOptions.ForceSynchronousImport);
            var importer=AssetImporter.GetAtPath(path) as TextureImporter;if(importer==null)throw new InvalidDataException("Missing V4 texture importer: "+path);
            importer.textureType=normal?TextureImporterType.NormalMap:TextureImporterType.Default;importer.sRGBTexture=!normal&&!linear;
            // The reviewed ocean card deliberately overscans beyond UV 0..1.
            // Match Blender's EXTEND sampler: Repeat exposes a second coast at
            // the top and sides when standing beside the panoramic window.
            if(relative=="Textures/Baked_Ocean.png")importer.wrapMode=TextureWrapMode.Clamp;
            importer.mipmapEnabled=true;importer.maxTextureSize=4096;importer.isReadable=false;importer.SaveAndReimport();
            return AssetDatabase.LoadAssetAtPath<Texture2D>(path)??throw new InvalidDataException("Missing V4 texture: "+path);
        }
        public static string TexturePath(string relative)
        {if(string.IsNullOrWhiteSpace(relative)||relative.Contains("\\")||relative.Contains(":")||relative.StartsWith("/")||relative.Split('/').Any(x=>x==".."||x=="."||x.Length==0)||!relative.EndsWith(".png",StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Texture escaped the V4 package.");return AssetRoot+"/"+relative;}
        private static Bounds LocalGeometryBounds(Transform root,Renderer renderer)
        {Bounds world=CoastalRoomV2Importer.GeometryBounds(renderer);return new Bounds(root.InverseTransformPoint(world.center),world.size);}
        private static bool BlocksFloor(string source)=>source.StartsWith("V2_Sofa",StringComparison.Ordinal)||source.StartsWith("V2_Lounge",StringComparison.Ordinal)||source.StartsWith("V2_Reading",StringComparison.Ordinal)||source.StartsWith("V2_Elliptical",StringComparison.Ordinal)||source.StartsWith("V2_Coffee",StringComparison.Ordinal)||source.StartsWith("V2_WorkChair",StringComparison.Ordinal)||source.StartsWith("V2_WorkDesk",StringComparison.Ordinal)||source.StartsWith("V2_Sideboard",StringComparison.Ordinal);
        public static Bounds Rect(float[] a){if(a?.Length!=4||a.Any(x=>!Finite(x))||a[0]>=a[2]||a[1]>=a[3])throw new InvalidDataException("Invalid room rectangle.");return new Bounds(new Vector3((a[0]+a[2])*.5f,.05f,(a[1]+a[3])*.5f),new Vector3(a[2]-a[0],.1f,a[3]-a[1]));}
        private static Bounds Bounds3(float[] a){if(a?.Length!=6||a.Any(x=>!Finite(x))||a[0]>=a[3]||a[1]>a[4]||a[2]>=a[5])throw new InvalidDataException("Invalid spatial bounds.");return new Bounds(new Vector3((a[0]+a[3])*.5f,(a[1]+a[4])*.5f,(a[2]+a[5])*.5f),new Vector3(a[3]-a[0],a[4]-a[1],a[5]-a[2]));}
        private static Bounds BlenderBounds(float[] a){Bounds3(a);return Bounds3(new[]{-a[3],a[2],-a[4],-a[0],a[5],-a[1]});}
        private static Vector3 Vector(float[] a){if(a?.Length!=3||a.Any(x=>!Finite(x)))throw new InvalidDataException("Invalid source vector.");return new Vector3(a[0],a[1],a[2]);}
        private static Transform Find(GameObject root,string name){var matches=root.GetComponentsInChildren<Transform>(true).Where(x=>x.name==name).ToArray();if(matches.Length!=1)throw new InvalidDataException("V4 requires one node: "+name);return matches[0];}
        private static void Unique(IEnumerable<string> names,string kind){var set=new HashSet<string>(StringComparer.Ordinal);foreach(string name in names)if(string.IsNullOrWhiteSpace(name)||!set.Add(name))throw new InvalidDataException("Invalid/duplicate "+kind);}
        private static string SafeName(string value){if(string.IsNullOrWhiteSpace(value)||value.Any(c=>!char.IsLetterOrDigit(c)&&c!='_'&&c!='-'&&c!='.'))throw new InvalidDataException("Invalid material name.");return value;}
        private static bool Hash(string value)=>value!=null&&value.Length==64&&value.All(c=>c>='0'&&c<='9'||c>='a'&&c<='f');
        private static bool Finite(float value)=>!float.IsNaN(value)&&!float.IsInfinity(value);
        private static string ProjectFile(string path)=>Path.GetFullPath(Path.Combine(Application.dataPath,"..",path));
        private static string Digest(string path){using var hash=SHA256.Create();return BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(path))).Replace("-","").ToLowerInvariant();}
    }
}
#endif
