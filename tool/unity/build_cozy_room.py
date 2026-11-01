#!/usr/bin/env python3
"""Build Maaso's self-contained warm apartment in a clean Blender process.

Run: /Applications/Blender.app/Contents/MacOS/Blender --background \
    --factory-startup --python tool/unity/build_cozy_room.py -- --skip-render

Authored coordinates use Unity metres: X right, Y up, Z toward the front camera.
Only mesh objects in the export collection enter FBX/glTF. Preview lighting and
camera remain in the editable .blend. No downloaded assets are required.
"""

import argparse
import json
import math
import random
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/avatar/cozy_room"
RNG = random.Random(250905)
MATERIALS = {}
EXPORT = None


def unity(x, y, z):
    return Vector((x, -z, y))


def material(name, color, roughness=0.65, metallic=0.0):
    value = bpy.data.materials.new(name)
    value.diffuse_color = (*color, 1.0)
    value.use_nodes = True
    shader = value.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*color, 1.0)
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    value.roughness = roughness
    value.metallic = metallic
    MATERIALS[name] = value
    return value


def palette():
    material("Cozy_Plaster_Ivory", (0.91, 0.87, 0.79), 0.92)
    material("Cozy_Ceiling_Cream", (0.94, 0.92, 0.86), 0.93)
    material("Cozy_Oak_Honey", (0.79, 0.65, 0.47), 0.64)
    material("Cozy_Oak_Edge", (0.84, 0.73, 0.56), 0.64)
    for index in range(9):
        level = 0.95 + index * 0.012
        material("Cozy_Oak_Plank_%02d" % index,
                 (0.84 * level, 0.73 * level, 0.56 * level), 0.67)
    material("Cozy_Linen_Ivory", (0.94, 0.91, 0.84), 0.93)
    material("Cozy_Linen_Shadow", (0.74, 0.68, 0.57), 0.94)
    material("Cozy_Boucle_Oatmeal", (0.89, 0.83, 0.72), 0.91)
    material("Cozy_Cushion_Cream", (0.95, 0.91, 0.82), 0.93)
    material("Cozy_Cushion_Sage", (0.47, 0.53, 0.39), 0.89)
    material("Cozy_Rug_Oatmeal", (0.76, 0.66, 0.51), 0.99)
    material("Cozy_Rug_Seam", (0.84, 0.76, 0.63), 0.98)
    material("Cozy_Ceramic_Cream", (0.92, 0.87, 0.76), 0.55)
    material("Cozy_Ceramic_Clay", (0.67, 0.43, 0.29), 0.73)
    material("Cozy_Stone_Travertine", (0.87, 0.80, 0.67), 0.86)
    material("Cozy_Leaf_Sage", (0.25, 0.38, 0.14), 0.68)
    material("Cozy_Leaf_Light", (0.39, 0.50, 0.23), 0.64)
    material("Cozy_Leaf_Dark", (0.13, 0.27, 0.095), 0.68)
    material("Cozy_Stem", (0.30, 0.25, 0.13), 0.88)
    material("Cozy_Soil", (0.075, 0.038, 0.018), 1.0)
    material("Cozy_Brass", (0.47, 0.31, 0.11), 0.38, 0.72)
    material("Cozy_Bronze", (0.19, 0.17, 0.13), 0.40, 0.55)
    material("Cozy_Lamp_Warm", (1.0, 0.73, 0.33), 0.9)
    lamp = MATERIALS["Cozy_Lamp_Warm"].node_tree.nodes.get("Principled BSDF")
    lamp.inputs["Emission Color"].default_value = (1.0, 0.63, 0.25, 1.0)
    lamp.inputs["Emission Strength"].default_value = 0.45
    material("Cozy_Book_Sage", (0.28, 0.36, 0.27), 0.88)
    material("Cozy_Book_Clay", (0.55, 0.31, 0.20), 0.88)
    material("Cozy_Book_Paper", (0.79, 0.71, 0.56), 0.94)
    material("Cozy_Seascape", (1.0, 1.0, 1.0), 1.0)


def own(obj, name, mat):
    obj.name = name
    for collection in tuple(obj.users_collection):
        collection.objects.unlink(obj)
    EXPORT.objects.link(obj)
    if mat:
        obj.data.materials.append(MATERIALS[mat])
    return obj


def apply_scale(obj):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.select_set(False)


def bevel(obj, amount=0.03, segments=3):
    if amount <= 0:
        return
    modifier = obj.modifiers.new("Soft manufactured edges", "BEVEL")
    modifier.width = amount
    modifier.segments = segments
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    weighted = obj.modifiers.new("Weighted corner normals", "WEIGHTED_NORMAL")
    bpy.ops.object.modifier_apply(modifier=weighted.name)


def box(name, center, size, mat, radius=0.02):
    bpy.ops.mesh.primitive_cube_add(size=1, location=unity(*center))
    obj = own(bpy.context.object, name, mat)
    obj.dimensions = (size[0], size[2], size[1])
    apply_scale(obj)
    bevel(obj, min(radius, min(size) * 0.45), 4 if radius > 0.08 else 2)
    return obj


def sphere(name, center, scale, mat, segments=24, rings=12):
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=segments, ring_count=rings, radius=1, location=unity(*center))
    obj = own(bpy.context.object, name, mat)
    obj.scale = (scale[0], scale[2], scale[1])
    apply_scale(obj)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def cylinder(name, center, radius, depth, mat, vertices=32, radius_top=None):
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices, radius1=radius,
        radius2=radius if radius_top is None else radius_top,
        depth=depth, location=unity(*center))
    obj = own(bpy.context.object, name, mat)
    bevel(obj, min(0.015, depth * 0.1), 2)
    return obj


def rod(name, start, end, radius, mat, vertices=12):
    a, b = unity(*start), unity(*end)
    direction = b - a
    bpy.ops.mesh.primitive_cone_add(
        vertices=vertices, radius1=radius, radius2=radius * 0.8,
        depth=direction.length, location=(a + b) / 2)
    obj = own(bpy.context.object, name, mat)
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def mesh(name, vertices, faces, mat):
    data = bpy.data.meshes.new(name + "_Mesh")
    data.from_pydata([unity(*v) for v in vertices], [], faces)
    data.update()
    obj = bpy.data.objects.new(name, data)
    EXPORT.objects.link(obj)
    data.materials.append(MATERIALS[mat])
    return obj


def join(objects, name):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    result = bpy.context.object
    result.name = name
    result.select_set(False)
    return result


def surface_uv(obj, tile_metres=1.0, plank=False):
    """World-scale box projection; floor planks each get one grain tile."""
    data = obj.data
    data.update()
    uv = data.uv_layers.get("UVMap") or data.uv_layers.new(name="UVMap")
    low = Vector(tuple(min(v.co[i] for v in data.vertices) for i in range(3)))
    high = Vector(tuple(max(v.co[i] for v in data.vertices) for i in range(3)))
    size = high - low
    for polygon in data.polygons:
        dominant = max(range(3), key=lambda axis: abs(polygon.normal[axis]))
        axes = ((1, 2), (0, 2), (0, 1))[dominant]
        for loop_index in polygon.loop_indices:
            coordinate = data.vertices[data.loops[loop_index].vertex_index].co
            if plank:
                value = tuple((coordinate[axis] - low[axis]) / max(size[axis], 0.001)
                              for axis in axes)
            else:
                value = tuple(coordinate[axis] / tile_metres for axis in axes)
            uv.data[loop_index].uv = value


def prepare_material_surfaces():
    """Bundle the same texture details in Blender/glTF and the Unity prefab."""
    texture_directory = ROOT / "unity/masso_avatar/Assets/MaasoWorld/PersonalSpace/Textures"
    for obj in EXPORT.objects:
        if obj.name == "PS_Floor" or obj.name == "PS_Exterior_Sky" or "_Leaves" in obj.name:
            continue
        names = [mat.name for mat in obj.data.materials]
        fabric = any(name.startswith(("Cozy_Linen", "Cozy_Boucle", "Cozy_Cushion", "Cozy_Rug"))
                     for name in names)
        surface_uv(obj, 0.35 if fabric else 1.0)
    for name, mat in MATERIALS.items():
        key = None
        if name.startswith("Cozy_Oak_"):
            key = "oak"
        elif name.startswith(("Cozy_Linen", "Cozy_Boucle", "Cozy_Cushion", "Cozy_Rug")):
            key = "linen"
        elif name.startswith(("Cozy_Plaster", "Cozy_Ceiling", "Cozy_Stone")):
            key = "plaster"
        coastal = name == "Cozy_Seascape"
        if not key and not coastal:
            continue
        filename = "coastal_seaview.png" if coastal else key + "_albedo.png"
        path = texture_directory / filename
        if not path.exists():
            raise FileNotFoundError("Bake room materials and supply the coastal vista first: " + str(path))
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        shader = nodes.get("Principled BSDF")
        texture = nodes.new("ShaderNodeTexImage")
        texture.image = bpy.data.images.load(str(path), check_existing=True)
        texture.image.pack()
        texture.extension = "EXTEND" if coastal else "REPEAT"
        if coastal:
            shader.inputs["Base Color"].default_value = (0, 0, 0, 1)
            links.new(texture.outputs["Color"], shader.inputs["Emission Color"])
            shader.inputs["Emission Strength"].default_value = 0.92
        else:
            tint = nodes.new("ShaderNodeMix")
            tint.data_type = "RGBA"
            tint.blend_type = "MULTIPLY"
            tint.inputs[0].default_value = 1.0
            tint.inputs[6].default_value = mat.diffuse_color
            links.new(texture.outputs["Color"], tint.inputs[7])
            links.new(tint.outputs[2], shader.inputs["Base Color"])


def floor_and_shell():
    slab = box("Floor slab", (0, -0.075, 0), (12, 0.15, 12), "Cozy_Oak_Honey", 0)
    planks = []
    width, length = 0.32, 2.4
    for row in range(38):
        x0, x1 = -6 + row * width, min(6, -6 + (row + 1) * width)
        offset = (row % 3) * (length / 3)
        z = -6 - offset
        while z < 6:
            a, b = max(z, -6), min(z + length, 6)
            if b - a > 0.025:
                planks.append(box("Oak plank", ((x0 + x1) / 2, 0.006, (a + b) / 2),
                                  (x1 - x0 - 0.002, 0.008, b - a - 0.003),
                                  "Cozy_Oak_Plank_%02d" % RNG.randrange(9), 0.001))
            z += length
    for plank in [slab] + planks:
        surface_uv(plank, plank=True)
    join([slab] + planks, "PS_Floor")
    box("PS_Wall_Left", (-5.94, 1.92, 0), (0.12, 3.84, 12), "Cozy_Plaster_Ivory")
    box("PS_Wall_Right", (5.94, 1.92, 0), (0.12, 3.84, 12), "Cozy_Plaster_Ivory")
    box("PS_Wall_Back", (0, 1.92, 5.94), (12, 3.84, 0.12), "Cozy_Plaster_Ivory")
    box("PS_Ceiling", (0, 3.89, 0), (12, 0.1, 12), "Cozy_Ceiling_Cream")
    box("PS_Window_Wall_Base", (0, 0.055, -4.94), (11.8, 0.11, 0.18), "Cozy_Plaster_Ivory")
    box("PS_Window_Wall_Header", (0, 3.69, -4.94), (11.8, 0.3, 0.18), "Cozy_Plaster_Ivory")
    for x in (-5.17, 5.17):
        box("PS_Window_Wall_Pier", (x, 1.82, -4.94), (1.46, 3.44, 0.18), "Cozy_Plaster_Ivory")
    baseboards = []
    for x in (-5.84, 5.84):
        baseboards.append(box("Skirting", (x, 0.105, 0), (0.04, 0.19, 11.8), "Cozy_Oak_Edge"))
    join(baseboards, "PS_Wall_Skirting")


def curtain(name, x0, x1, z):
    columns, rows = 80, 18
    vertices, faces = [], []
    for row in range(rows + 1):
        t = row / rows
        # Soft gathering at waist, broader hem and header.
        gather = 0.82 + 0.18 * abs(2 * t - 1)
        for col in range(columns + 1):
            u = col / columns
            x = (x0 + x1) / 2 + (u - 0.5) * (x1 - x0) * gather
            wave = math.sin(u * math.pi * 16)
            zz = z + wave * (0.058 + 0.035 * t)
            height = 3.45 - t * 3.36 + 0.024 * math.cos(u * math.pi * 16) * t
            vertices.append((x, height, zz))
    for row in range(rows):
        for col in range(columns):
            a = row * (columns + 1) + col
            faces.append((a, a + 1, a + columns + 2, a + columns + 1))
    obj = mesh(name, vertices, faces, "Cozy_Linen_Ivory")
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    solidify = obj.modifiers.new("Linen thickness", "SOLIDIFY")
    solidify.thickness = 0.005
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=solidify.name)
    return obj


def windows():
    frames = []
    for x in (-4.44, -1.48, 1.48, 4.44):
        frames.append(box("Window mullion", (x, 1.82, -4.80), (0.046, 3.44, 0.095), "Cozy_Bronze", 0.005))
    for y in (0.10, 3.54):
        frames.append(box("Window rail", (0, y, -4.80), (8.94, 0.047, 0.095), "Cozy_Bronze", 0.005))
    join(frames, "PS_Window_Frame")
    box("PS_Window_Sill", (0, 0.085, -4.70), (9.08, 0.06, 0.26), "Cozy_Stone_Travertine", 0.01)
    for x in (-1.42, 1.42):
        box("PS_Window_Handle", (x, 1.18, -4.72), (0.018, 0.19, 0.028), "Cozy_Bronze", 0.006)
    rod("PS_Curtain_Rail", (-4.66, 3.57, -4.48), (4.66, 3.57, -4.48), 0.017, "Cozy_Brass")
    curtain("PS_Curtain_Left", -4.62, -3.48, -4.44)
    curtain("PS_Curtain_Right", 3.48, 4.62, -4.44)
    # Glass is intentionally absent: clear openings stay transparent in every
    # Unity render pipeline without external shaders or alpha sorting artifacts.


def sofa():
    x, z = 3.48, -3.13
    box("PS_Sofa_Base", (x, 0.25, z), (2.55, 0.36, 1.16), "Cozy_Oak_Honey", 0.15)
    box("PS_Sofa_Seat", (x, 0.51, z + 0.04), (2.66, 0.40, 1.27), "Cozy_Boucle_Oatmeal", 0.19)
    box("PS_Sofa_Back", (x, 0.91, z - 0.52), (2.70, 0.85, 0.37), "Cozy_Boucle_Oatmeal", 0.17)
    for dx in (-1.20, 1.20):
        box("PS_Sofa_Arm", (x + dx, 0.71, z), (0.36, 0.59, 1.28), "Cozy_Boucle_Oatmeal", 0.175)
    for dx, mat in ((-0.72, "Cozy_Cushion_Cream"), (0.62, "Cozy_Cushion_Sage")):
        pillow = box("PS_Sofa_Cushion", (x + dx, 0.96, z - 0.27),
                     (0.63, 0.62, 0.23), mat, 0.11)
        pillow.rotation_euler.x = math.radians(-13)
        pillow.rotation_euler.y = math.radians(9 if dx < 0 else -9)
    for dx in (-0.60, 0.60):
        box("PS_Sofa_Seat_Seam", (x + dx, 0.706, z + 0.04),
            (0.004, 0.004, 0.9), "Cozy_Linen_Shadow", 0)
    box("PS_Rug_Border", (3.38, 0.021, -2.53), (4.0, 0.02, 3.2), "Cozy_Rug_Seam", 0.008)
    box("PS_Rug", (3.38, 0.033, -2.53), (3.89, 0.012, 3.09), "Cozy_Rug_Oatmeal", 0.005)


def lathe(name, center, profile, mat, segments=40):
    vertices, faces = [], []
    for radius, height in profile:
        for k in range(segments):
            angle = math.tau * k / segments
            vertices.append((center[0] + radius * math.cos(angle),
                             center[1] + height,
                             center[2] + radius * math.sin(angle)))
    for row in range(len(profile) - 1):
        for k in range(segments):
            a = row * segments + k
            b = row * segments + (k + 1) % segments
            faces.append((a, a + segments, b + segments, b))
    obj = mesh(name, vertices, faces, mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def furniture():
    # A low stone coffee table stays outside the companion's standing circle.
    x, z = 3.04, -1.74
    cylinder("PS_Desk_Top", (x, 0.43, z), 0.64, 0.085, "Cozy_Stone_Travertine", 64)
    cylinder("PS_Desk_Pedestal", (x, 0.22, z), 0.23, 0.42, "Cozy_Stone_Travertine", 40, 0.23)
    lathe("PS_Table_Cup", (x - 0.08, 0.476, z),
          [(0, 0), (0.07, 0), (0.078, 0.11), (0.065, 0.115), (0.058, 0.015), (0, 0.015)],
          "Cozy_Ceramic_Cream", 32)
    cylinder("PS_Table_Cup_Coffee", (x - 0.08, 0.564, z), 0.059, 0.002, "Cozy_Soil", 32)
    for index in range(2):
        box("PS_Table_ArtBook", (x + 0.19, 0.497 + index * 0.045, z + 0.11),
            (0.34, 0.039, 0.27), ("Cozy_Book_Paper", "Cozy_Book_Sage")[index], 0.004)
    # The personal space keeps a usable sleeping nook, off the Home camera.
    x, z = -4.28, 2.38
    box("PS_Bed_Platform", (x, 0.23, z), (2.24, 0.34, 2.77), "Cozy_Oak_Honey", 0.065)
    box("PS_Bed_Cushion", (x, 0.49, z), (2.19, 0.24, 2.67), "Cozy_Linen_Ivory", 0.115)
    box("PS_Bed_Headboard", (x, 0.71, z + 1.30), (2.3, 1.14, 0.13), "Cozy_Oak_Edge", 0.06)
    for dx in (-0.53, 0.53):
        box("PS_Bed_Pillow", (x + dx, 0.70, z + 0.83),
            (0.86, 0.20, 0.54), "Cozy_Cushion_Cream", 0.095)
    box("PS_Bed_Throw", (x, 0.64, z - 0.74), (2.18, 0.028, 0.72), "Cozy_Cushion_Sage", 0.012)
    # Low oak console and shelves frame the left side of the room.
    x, z = -4.34, -1.92
    cabinet = [box("Cabinet base", (x, 0.15, z), (2.16, 0.13, 0.58), "Cozy_Oak_Honey")]
    for dx in (-1.01, 0, 1.01):
        cabinet.append(box("Cabinet side", (x + dx, 0.69, z), (0.10, 1.04, 0.58), "Cozy_Oak_Edge"))
    for y in (0.57, 1.23):
        cabinet.append(box("Cabinet shelf", (x, y, z), (2.16, 0.08, 0.62), "Cozy_Oak_Edge"))
    cabinet.append(box("Cabinet back", (x, 0.67, z - 0.27), (2.08, 1.14, 0.045), "Cozy_Oak_Honey"))
    join(cabinet, "PS_Storage_Cabinet")
    for section in range(2):
        for i in range(5):
            bx = x - 0.88 + section * 1.05 + i * 0.115
            height = RNG.uniform(0.25, 0.43)
            mat = ("Cozy_Book_Sage", "Cozy_Book_Clay", "Cozy_Book_Paper")[i % 3]
            box("PS_Storage_Book", (bx, 0.61 + height / 2, z + 0.03), (0.082, height, 0.24), mat, 0.007)
    for i in range(3):
        box("PS_Storage_Book_Stack", (x + 0.60, 0.235 + i * 0.065, z),
            (0.43, 0.052, 0.32), ("Cozy_Book_Paper", "Cozy_Book_Clay", "Cozy_Book_Sage")[i])
    lathe("PS_Storage_Vase", (x - 0.49, 1.28, z),
          [(0, 0), (0.12, 0), (0.16, 0.08), (0.13, 0.24), (0.062, 0.36), (0.056, 0.36), (0.053, 0.32)],
          "Cozy_Ceramic_Clay")
    lamp_x, lamp_z = -1.82, -4.02
    cylinder("PS_FloorLamp_Base", (lamp_x, 0.048, lamp_z), 0.34, 0.075, "Cozy_Oak_Honey", 48)
    rod("PS_FloorLamp_Stand", (lamp_x, 0.08, lamp_z), (lamp_x, 1.82, lamp_z), 0.042, "Cozy_Oak_Edge", 20)
    lathe("PS_FloorLamp_Shade", (lamp_x, 1.70, lamp_z),
          [(0.46, 0), (0.465, 0.025), (0.385, 0.61), (0.373, 0.61), (0.450, 0.025), (0.46, 0)],
          "Cozy_Linen_Ivory", 64)
    sphere("PS_FloorLamp_Bulb", (lamp_x, 1.97, lamp_z), (0.095, 0.11, 0.095), "Cozy_Lamp_Warm")
    # Light oak lounge chair with separated legs and fabric cushions.
    x, z = -2.92, -3.30
    for dx in (-0.45, 0.45):
        rod("PS_Armchair_FrontLeg", (x + dx, 0.05, z + 0.39),
            (x + dx * 0.92, 0.61, z + 0.27), 0.032, "Cozy_Oak_Honey")
        rod("PS_Armchair_RearLeg", (x + dx, 0.05, z - 0.43),
            (x + dx * 0.95, 0.99, z - 0.38), 0.032, "Cozy_Oak_Honey")
        box("PS_Armchair_Arm", (x + dx, 0.70, z), (0.073, 0.062, 0.98), "Cozy_Oak_Edge", 0.028)
    box("PS_Armchair_Seat", (x, 0.49, z), (0.85, 0.20, 0.84), "Cozy_Cushion_Cream", 0.085)
    chair_back = box("PS_Armchair_Back", (x, 0.85, z - 0.34),
                     (0.87, 0.62, 0.19), "Cozy_Cushion_Cream", 0.078)
    chair_back.rotation_euler.x = math.radians(-12)


def leaf_blade(name, start, end, half_width, mat, bend=0.10):
    """A pointed, gently folded botanical blade, never a closed ellipsoid."""
    a, b = Vector(start), Vector(end)
    direction = (b - a).normalized()
    length = (b - a).length
    facing = Vector((0.1, 0.65, 1.0)).normalized()
    across = direction.cross(facing).normalized()
    normal = across.cross(direction).normalized()
    vertices, faces, texcoords = [], [], []
    rows, columns = (12, 4) if length > 0.35 else (7, 2)
    for row in range(rows + 1):
        t = row / rows
        center = a.lerp(b, t)
        center += normal * (math.sin(math.pi * t) * length * bend)
        center.y -= length * 0.08 * t ** 3
        width = half_width * max(0.003, math.sin(math.pi * t) ** 0.82)
        for col in range(columns + 1):
            side = col / columns * 2 - 1
            point = center + across * (width * side)
            point -= normal * (abs(side) * width * 0.18)
            vertices.append(tuple(point))
            texcoords.append((col / columns, t))
    for row in range(rows):
        for col in range(columns):
            a_index = row * (columns + 1) + col
            faces.append((a_index, a_index + 1, a_index + columns + 2, a_index + columns + 1))
    blade = mesh(name, vertices, faces, mat)
    uv = blade.data.uv_layers.new(name="UVMap")
    for loop in blade.data.loops:
        uv.data[loop.index].uv = texcoords[loop.vertex_index]
    for polygon in blade.data.polygons:
        polygon.use_smooth = True
    # Thin back faces remain visible during a walk around the plant in Unity.
    modifier = blade.modifiers.new("Botanical leaf thickness", "SOLIDIFY")
    modifier.thickness = 0.0012
    bpy.context.view_layer.objects.active = blade
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    return blade


def plant(label, x, z, base, height, radius):
    pot_height = height * 0.22
    lathe("PS_Plant_" + label + "_Pot", (x, base, z),
          [(0, 0), (radius * 0.73, 0), (radius * 0.96, pot_height * 0.12),
           (radius, pot_height * 0.7), (radius * 0.84, pot_height),
           (radius * 0.76, pot_height), (radius * 0.70, pot_height * 0.68)],
          "Cozy_Ceramic_Cream", 32)
    cylinder("PS_Plant_" + label + "_Soil", (x, base + pot_height * 0.80, z),
             radius * 0.79, 0.015, "Cozy_Soil", 24)
    stems, leaves = [], []
    start = base + pot_height * 0.75
    broad_leaf = label == "Tall"
    for stem_index in range(12 if broad_leaf else 15):
        angle = stem_index * 2.40 + 0.3
        extent = radius * RNG.uniform(1.0, 2.6)
        top = base + height * RNG.uniform(0.73, 1.0)
        tip_x = x + math.cos(angle) * extent
        tip_z = z + math.sin(angle) * extent
        stems.append(rod("Plant stem", (x, start, z), (tip_x, top, tip_z),
                         max(0.006, radius * 0.026), "Cozy_Stem", 8))
        for leaf_index in range(1 if broad_leaf else 11):
            t = 1.0 if broad_leaf else 0.40 + leaf_index * 0.054
            cy = start + (top - start) * t
            cx = x + (tip_x - x) * t
            cz = z + (tip_z - z) * t
            la = angle + leaf_index * 2.35
            size = radius * RNG.uniform(1.8, 2.7) if broad_leaf else radius * RNG.uniform(0.58, 0.87)
            tip = (cx + math.cos(la) * size * 0.80,
                   cy + size * (0.64 if broad_leaf else RNG.uniform(-0.10, 0.34)),
                   cz + math.sin(la) * size * 0.80)
            leaves.append(leaf_blade("Plant leaf", (cx, cy, cz), tip,
                          size * (0.19 if broad_leaf else 0.12),
                          ("Cozy_Leaf_Sage", "Cozy_Leaf_Light", "Cozy_Leaf_Dark")[(stem_index + leaf_index) % 3]))
    join(stems, "PS_Plant_" + label + "_Stems")
    join(leaves, "PS_Plant_" + label + "_Leaves")


def exterior():
    # A local photographic vista replaces the close-up block buildings. Keep
    # the semantic name for camera occlusion and the stable 12m room bounds.
    vista = mesh("PS_Exterior_Sky", [(-5.91, 0.01, -5.92), (5.91, 0.01, -5.92),
                                  (5.91, 3.89, -5.92), (-5.91, 3.89, -5.92)],
                 [(0, 1, 2, 3)], "Cozy_Seascape")
    uv = vista.data.uv_layers.new(name="UVMap")
    # Crop the 16:9 photo in UV space for this wide window; do not stretch its
    # coast or water. The horizon remains near a standing person's eye height.
    crop_height = (16 / 9) / (11.82 / 3.88)
    for index, coordinate in enumerate(((0, 0.27), (1, 0.27),
                                         (1, 0.27 + crop_height), (0, 0.27 + crop_height))):
        uv.data[index].uv = coordinate


def preview():
    scene = bpy.context.scene
    preview_collection = bpy.data.collections.new("PREVIEW_ONLY")
    scene.collection.children.link(preview_collection)

    def light(name, location, energy, color, kind="AREA", size=4.0, target=(0, 1, -1)):
        data = bpy.data.lights.new("PREVIEW_ONLY_" + name, kind)
        data.energy = energy
        data.color = color
        if kind == "AREA":
            data.shape = "DISK"
            data.size = size
        obj = bpy.data.objects.new(data.name, data)
        preview_collection.objects.link(obj)
        obj.location = unity(*location)
        obj.rotation_euler = (unity(*target) - obj.location).to_track_quat("-Z", "Y").to_euler()
        return obj

    light("WindowSunlight", (-3.5, 3.0, -4.55), 650, (1.0, 0.79, 0.53), size=3.2, target=(1, 0, 1))
    light("WindowAmbient", (2.5, 3.1, -4.4), 350, (0.74, 0.84, 1.0), size=4.0)
    light("FrontSoftbox", (0, 3.3, 4.0), 110, (1.0, 0.88, 0.72), size=5.0, target=(0, 1.3, -2.5))
    lamp = light("FloorLamp", (-1.72, 1.94, -4.02), 25, (1.0, 0.67, 0.33), kind="POINT")
    lamp.data.shadow_soft_size = 0.18
    world = bpy.data.worlds.new("Warm daylight")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.70, 0.81, 0.90, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.18
    camera_data = bpy.data.cameras.new("PREVIEW_ONLY_PortraitCamera")
    camera = bpy.data.objects.new(camera_data.name, camera_data)
    preview_collection.objects.link(camera)
    camera.location = unity(0.10, 0.90, 4.1)
    camera.rotation_euler = (unity(0, 0.90, -2.0) - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera_data.lens = 53
    camera_data.sensor_fit = "VERTICAL"
    camera_data.sensor_height = 36
    camera_data.clip_start = 0.05
    camera_data.clip_end = 80
    camera_data.dof.use_dof = True
    camera_data.dof.focus_distance = (unity(0, 1.5, -1.8) - camera.location).length
    camera_data.dof.aperture_fstop = 5.6
    scene.camera = camera
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 48
    scene.cycles.use_denoising = True
    scene.cycles.adaptive_threshold = 0.05
    scene.cycles.max_bounces = 6
    scene.render.resolution_x = 720
    scene.render.resolution_y = 1280
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(OUT / "agent_cozy_room_blender.png")
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.exposure = 0.30


def export_unity_fbx(objects, fbx_path):
    """Compensate Unity FBX handedness without mirroring the authoring scene.

    Unity's FBX importer maps Blender (X, Y, Z) to Unity (X, Z, Y),
    experimentally verified from the imported window/lamp bounds. The authoring
    scene and glTF use the usual right-handed (X, Z, -Y) conversion instead.
    Reflect Blender Y for FBX only, and reverse winding to retain outward faces.
    """
    mirror = Matrix.Diagonal((1, -1, 1, 1))
    copies = []
    source_names = [(obj, obj.name) for obj in objects]
    bpy.ops.object.select_all(action="DESELECT")
    try:
        for source, name in source_names:
            source.name = "AUTHORING_ONLY_" + name
        for source, name in source_names:
            transform = mirror @ source.matrix_world
            pivot = transform.translation
            vertices = [transform @ vertex.co - pivot for vertex in source.data.vertices]
            faces = [list(reversed(polygon.vertices)) for polygon in source.data.polygons]
            data = bpy.data.meshes.new(name + "_UnityFBX")
            data.from_pydata(vertices, [], faces)
            for mat in source.data.materials:
                data.materials.append(mat)
            for polygon, original in zip(data.polygons, source.data.polygons):
                polygon.material_index = original.material_index
                polygon.use_smooth = original.use_smooth
            # Mirroring reverses each face. Carry loop UVs in the same reversed
            # order; rebuilding vertices alone silently discarded all textures.
            for original_uv in source.data.uv_layers:
                copied_uv = data.uv_layers.new(name=original_uv.name)
                for polygon, original in zip(data.polygons, source.data.polygons):
                    for loop_index, source_index in zip(
                            polygon.loop_indices, reversed(original.loop_indices)):
                        copied_uv.data[loop_index].uv = original_uv.data[source_index].uv
            data.update()
            obj = bpy.data.objects.new(name, data)
            bpy.context.scene.collection.objects.link(obj)
            obj.location = pivot
            obj.select_set(True)
            # Rebuild weighted normals after the reflection rather than copying
            # stale custom corner normals from the source mesh.
            obj.modifiers.new("Unity FBX weighted normals", "WEIGHTED_NORMAL")
            copies.append(obj)
        bpy.context.view_layer.objects.active = copies[0]
        bpy.context.view_layer.update()
        bpy.ops.export_scene.fbx(
            filepath=str(fbx_path), use_selection=True, object_types={"MESH"},
            global_scale=1.0, apply_unit_scale=True, apply_scale_options="FBX_SCALE_UNITS",
            axis_forward="-Z", axis_up="Y", bake_space_transform=True,
            use_mesh_modifiers=True, mesh_smooth_type="FACE", use_triangles=True,
            use_custom_props=False, bake_anim=False, add_leaf_bones=False,
            path_mode="AUTO", embed_textures=False)
    finally:
        for obj in copies:
            data = obj.data
            bpy.data.objects.remove(obj, do_unlink=True)
            bpy.data.meshes.remove(data)
        for source, name in source_names:
            source.name = name
            source.select_set(True)
        bpy.context.view_layer.objects.active = objects[0]


def validate_and_export(fbx_path):
    bpy.context.view_layer.update()
    objects = list(EXPORT.objects)
    names = {obj.name for obj in objects}
    required = {"PS_Floor", "PS_Sofa_Seat", "PS_Desk_Top", "PS_Storage_Cabinet",
                "PS_Bed_Platform", "PS_Window_Frame", "PS_Curtain_Left", "PS_Curtain_Right"}
    if not required.issubset(names):
        raise RuntimeError("Missing semantic objects: " + repr(required - names))
    if any(obj.type != "MESH" or "PREVIEW_ONLY" in obj.name for obj in objects):
        raise RuntimeError("Export collection must contain environment meshes only")
    if any(name.startswith(("PS_Exterior_House", "PS_Exterior_Roof", "PS_Exterior_Window")) for name in names):
        raise RuntimeError("Retired block buildings must not enter the coastal room")
    for obj in objects:
        if not obj.data.uv_layers or len(obj.data.uv_layers.active.data) != len(obj.data.loops):
            raise RuntimeError("Missing per-corner texture coordinates: " + obj.name)
    corners = [obj.matrix_world @ Vector(corner) for obj in objects for corner in obj.bound_box]
    lo = Vector(tuple(min(point[i] for point in corners) for i in range(3)))
    hi = Vector(tuple(max(point[i] for point in corners) for i in range(3)))
    size = hi - lo
    if not (11 <= size.x <= 14 and 11 <= size.y <= 14 and 2.8 <= size.z <= 4.5):
        raise RuntimeError("Unexpected Blender-axis bounds: " + repr(size))
    furniture_prefixes = ("PS_Sofa", "PS_Desk", "PS_Storage", "PS_Bed", "PS_Plant", "PS_FloorLamp", "PS_Table")
    for obj in objects:
        if not obj.name.startswith(furniture_prefixes):
            continue
        points = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
        xmin, xmax = min(v.x for v in points), max(v.x for v in points)
        ymin, ymax = min(v.y for v in points), max(v.y for v in points)
        nearest_x = max(xmin, min(0, xmax))
        nearest_y = max(ymin, min(0, ymax))
        if math.hypot(nearest_x, nearest_y) < 2.25:
            raise RuntimeError("Furniture enters central 2.25m clearance: " + obj.name)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    export_unity_fbx(objects, fbx_path)
    bpy.ops.export_scene.gltf(
        filepath=str(OUT / "agent_cozy_room.glb"), export_format="GLB",
        use_selection=True, export_cameras=False, export_lights=False,
        export_yup=True, export_apply=True)
    report = {
        "generator": "tool/unity/build_cozy_room.py",
        "coordinate_system": "Unity X right, Y up, +Z front camera",
        "unity_bounds_size": [round(size.x, 5), round(size.z, 5), round(size.y, 5)],
        "floor_top": 0.01,
        "central_furniture_clearance_radius": 2.25,
        "visual_theme": "bright coastal ivory, light oak, linen and botanical leaf blades",
        "reference": "docs/avatar/coastal_room/reference-v1.png",
        "exterior": "local AI-generated photographic sea vista, no geometric buildings",
        "textures": ["coastal_seaview.png", "oak_albedo.png", "linen_albedo.png", "plaster_albedo.png"],
        "mesh_count": len(objects),
        "triangle_count": sum(len(p.vertices) - 2 for obj in objects for p in obj.data.polygons),
        "mesh_names": sorted(names),
        "materials": {name: {"base_color": list(mat.diffuse_color), "roughness": mat.roughness,
                              "metallic": mat.metallic} for name, mat in MATERIALS.items()},
        "fbx": str(fbx_path.relative_to(ROOT)) if fbx_path.is_relative_to(ROOT) else str(fbx_path),
        "preview": "docs/avatar/cozy_room/agent_cozy_room_blender.png",
    }
    (OUT / "model_manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    bpy.ops.object.select_all(action="DESELECT")
    print("COZY_ROOM_EXPORT_READY " + json.dumps({key: report[key] for key in
          ("fbx", "unity_bounds_size", "mesh_count", "triangle_count")}), flush=True)


def main():
    global EXPORT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-render", action="store_true")
    parser.add_argument("--fbx", type=Path, default=ROOT / "unity/masso_avatar/Assets/MaasoWorld/PersonalSpace/Models/PersonalSpace.fbx")
    parser.add_argument("--samples", type=int, default=48)
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    OUT.mkdir(parents=True, exist_ok=True)
    args.fbx.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    EXPORT = bpy.data.collections.new("Maaso_CozyRoom_EXPORT")
    bpy.context.scene.collection.children.link(EXPORT)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0
    palette()
    floor_and_shell()
    windows()
    sofa()
    furniture()
    plant("Tall", 2.10, -4.02, 0.01, 2.52, 0.30)
    plant("Olive", -2.65, -4.19, 0.01, 2.72, 0.29)
    plant("Shelf", -4.76, -1.92, 1.28, 0.47, 0.12)
    exterior()
    prepare_material_surfaces()
    preview()
    bpy.context.scene.cycles.samples = args.samples
    validate_and_export(args.fbx.resolve())
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "agent_cozy_room.blend"))
    if not args.skip_render:
        bpy.ops.render.render(write_still=True)
        print("COZY_ROOM_RENDER_READY " + bpy.context.scene.render.filepath, flush=True)


if __name__ == "__main__":
    main()
