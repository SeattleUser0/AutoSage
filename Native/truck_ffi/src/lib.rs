// SPDX-License-Identifier: MIT

use std::ffi::{CStr, CString};
use std::mem;
use std::os::raw::c_char;
use std::panic;
use std::ptr;

use truck_meshalgo::prelude::*;
use truck_polymesh::PolygonMesh;
use truck_stepio::r#in::Table;
use truck_topology::compress::CompressedShell;

#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub enum TruckErrorCode {
    Ok = 0,
    ErrInvalidArgument = 1,
    ErrIo = 2,
    ErrStepUnsupportedSchema = 3,
    ErrTessellationFailed = 4,
    ErrPanic = 5,
}

#[repr(C)]
pub struct TruckMeshResult {
    pub vertices: *mut f32,
    pub vertex_count: usize,
    pub vertex_capacity: usize,
    pub indices: *mut u32,
    pub index_count: usize,
    pub index_capacity: usize,
    pub volume: f64,
    pub surface_area: f64,
    pub bbox_min_x: f64,
    pub bbox_min_y: f64,
    pub bbox_min_z: f64,
    pub bbox_max_x: f64,
    pub bbox_max_y: f64,
    pub bbox_max_z: f64,
    pub watertight: u8,
    pub error_code: i32,
    pub error_message: *mut c_char,
}

struct OwnedMeshData {
    vertices: Vec<f32>,
    indices: Vec<u32>,
    volume: f64,
    surface_area: f64,
    bbox_min: [f64; 3],
    bbox_max: [f64; 3],
    watertight: bool,
}

#[no_mangle]
pub extern "C" fn truck_load_step(step_path: *const c_char, linear_deflection: f64) -> *mut TruckMeshResult {
    match panic::catch_unwind(|| truck_load_step_inner(step_path, linear_deflection)) {
        Ok(ptr) => ptr,
        Err(_) => make_error_result(TruckErrorCode::ErrPanic, "panic while processing STEP file"),
    }
}

#[no_mangle]
pub extern "C" fn truck_free_result(result_ptr: *mut TruckMeshResult) {
    if result_ptr.is_null() {
        return;
    }

    unsafe {
        let result = Box::from_raw(result_ptr);

        if !result.vertices.is_null() && result.vertex_capacity > 0 {
            let _ = Vec::from_raw_parts(result.vertices, result.vertex_count, result.vertex_capacity);
        }

        if !result.indices.is_null() && result.index_capacity > 0 {
            let _ = Vec::from_raw_parts(result.indices, result.index_count, result.index_capacity);
        }

        if !result.error_message.is_null() {
            let _ = CString::from_raw(result.error_message);
        }
    }
}

fn truck_load_step_inner(step_path: *const c_char, linear_deflection: f64) -> *mut TruckMeshResult {
    if step_path.is_null() {
        return make_error_result(TruckErrorCode::ErrInvalidArgument, "step_path must not be null");
    }

    if !linear_deflection.is_finite() || linear_deflection <= 0.0 {
        return make_error_result(
            TruckErrorCode::ErrInvalidArgument,
            "linear_deflection must be a positive finite number",
        );
    }

    let path = unsafe { CStr::from_ptr(step_path) };
    let path = match path.to_str() {
        Ok(value) => value.trim(),
        Err(_) => {
            return make_error_result(
                TruckErrorCode::ErrInvalidArgument,
                "step_path must be valid UTF-8",
            )
        }
    };

    if path.is_empty() {
        return make_error_result(
            TruckErrorCode::ErrInvalidArgument,
            "step_path must be a non-empty path",
        );
    }

    match load_mesh(path, linear_deflection) {
        Ok(mesh) => {
            let result = success_result(mesh);
            Box::into_raw(Box::new(result))
        }
        Err((code, message)) => make_error_result(code, message),
    }
}

fn load_mesh(path: &str, linear_deflection: f64) -> Result<OwnedMeshData, (TruckErrorCode, String)> {
    let step_file = std::fs::read_to_string(path)
        .map_err(|error| (TruckErrorCode::ErrIo, format!("failed to read STEP file: {error}")))?;

    let exchange = ruststep::parser::parse(&step_file).map_err(|error| {
        (
            TruckErrorCode::ErrStepUnsupportedSchema,
            format!("failed to parse STEP data: {error}"),
        )
    })?;

    let first_section = exchange.data.first().ok_or_else(|| {
        (
            TruckErrorCode::ErrStepUnsupportedSchema,
            String::from("STEP exchange contains no data section"),
        )
    })?;

    let table = Table::from_data_section(first_section);
    if table.shell.is_empty() {
        return Err((
            TruckErrorCode::ErrStepUnsupportedSchema,
            String::from("STEP file contains no shell geometry"),
        ));
    }

    let mut merged = PolygonMesh::default();
    for shell_holder in table.shell.values() {
        let shell: CompressedShell<_, _, _> = table.to_compressed_shell(shell_holder).map_err(|error| {
            (
                TruckErrorCode::ErrStepUnsupportedSchema,
                format!("failed to convert STEP shell: {error}"),
            )
        })?;

        let mut polygon = shell.robust_triangulation(linear_deflection).to_polygon();
        polygon
            .put_together_same_attrs(TOLERANCE * 50.0)
            .remove_degenerate_faces()
            .remove_unused_attrs();

        if !polygon.positions().is_empty() {
            merged.merge(polygon);
        }
    }

    if merged.positions().is_empty() {
        return Err((
            TruckErrorCode::ErrTessellationFailed,
            String::from("tessellation produced no vertices"),
        ));
    }

    let watertight = matches!(
        merged.shell_condition(),
        truck_topology::shell::ShellCondition::Closed
    );

    let position_mesh = merged.to_positions_mesh();
    let positions = position_mesh.positions();

    let mut bbox_min = [f64::INFINITY; 3];
    let mut bbox_max = [f64::NEG_INFINITY; 3];
    for point in positions {
        bbox_min[0] = bbox_min[0].min(point.x);
        bbox_min[1] = bbox_min[1].min(point.y);
        bbox_min[2] = bbox_min[2].min(point.z);

        bbox_max[0] = bbox_max[0].max(point.x);
        bbox_max[1] = bbox_max[1].max(point.y);
        bbox_max[2] = bbox_max[2].max(point.z);
    }

    let mut vertices = Vec::with_capacity(positions.len() * 3);
    for point in positions {
        vertices.push(point.x as f32);
        vertices.push(point.y as f32);
        vertices.push(point.z as f32);
    }

    let faces = position_mesh.faces();
    let mut indices = Vec::new();
    let mut surface_area = 0.0_f64;

    for tri in faces.tri_faces() {
        let tri_indices = [
            usize_to_u32(tri[0])?,
            usize_to_u32(tri[1])?,
            usize_to_u32(tri[2])?,
        ];
        indices.extend_from_slice(&tri_indices);
        surface_area += triangle_area(
            positions[tri[0]],
            positions[tri[1]],
            positions[tri[2]],
        );
    }

    for quad in faces.quad_faces() {
        let i0 = quad[0];
        let i1 = quad[1];
        let i2 = quad[2];
        let i3 = quad[3];

        indices.extend_from_slice(&[usize_to_u32(i0)?, usize_to_u32(i1)?, usize_to_u32(i2)?]);
        indices.extend_from_slice(&[usize_to_u32(i0)?, usize_to_u32(i2)?, usize_to_u32(i3)?]);

        surface_area += triangle_area(positions[i0], positions[i1], positions[i2]);
        surface_area += triangle_area(positions[i0], positions[i2], positions[i3]);
    }

    for polygon in faces.other_faces() {
        if polygon.len() < 3 {
            continue;
        }
        let base = polygon[0];
        for idx in 1..(polygon.len() - 1) {
            let i1 = polygon[idx];
            let i2 = polygon[idx + 1];
            indices.extend_from_slice(&[usize_to_u32(base)?, usize_to_u32(i1)?, usize_to_u32(i2)?]);
            surface_area += triangle_area(positions[base], positions[i1], positions[i2]);
        }
    }

    if indices.is_empty() {
        return Err((
            TruckErrorCode::ErrTessellationFailed,
            String::from("tessellation produced no triangle indices"),
        ));
    }

    Ok(OwnedMeshData {
        vertices,
        indices,
        volume: merged.volume().abs(),
        surface_area,
        bbox_min,
        bbox_max,
        watertight,
    })
}

fn usize_to_u32(value: usize) -> Result<u32, (TruckErrorCode, String)> {
    u32::try_from(value).map_err(|_| {
        (
            TruckErrorCode::ErrTessellationFailed,
            format!("index {value} exceeds u32 range"),
        )
    })
}

fn triangle_area(p0: Point3, p1: Point3, p2: Point3) -> f64 {
    let ux = p1.x - p0.x;
    let uy = p1.y - p0.y;
    let uz = p1.z - p0.z;

    let vx = p2.x - p0.x;
    let vy = p2.y - p0.y;
    let vz = p2.z - p0.z;

    let cx = uy * vz - uz * vy;
    let cy = uz * vx - ux * vz;
    let cz = ux * vy - uy * vx;

    0.5 * (cx * cx + cy * cy + cz * cz).sqrt()
}

fn success_result(mesh: OwnedMeshData) -> TruckMeshResult {
    let mut vertices = mesh.vertices;
    let mut indices = mesh.indices;

    let result = TruckMeshResult {
        vertices: vertices.as_mut_ptr(),
        vertex_count: vertices.len(),
        vertex_capacity: vertices.capacity(),
        indices: indices.as_mut_ptr(),
        index_count: indices.len(),
        index_capacity: indices.capacity(),
        volume: mesh.volume,
        surface_area: mesh.surface_area,
        bbox_min_x: mesh.bbox_min[0],
        bbox_min_y: mesh.bbox_min[1],
        bbox_min_z: mesh.bbox_min[2],
        bbox_max_x: mesh.bbox_max[0],
        bbox_max_y: mesh.bbox_max[1],
        bbox_max_z: mesh.bbox_max[2],
        watertight: if mesh.watertight { 1 } else { 0 },
        error_code: TruckErrorCode::Ok as i32,
        error_message: ptr::null_mut(),
    };

    mem::forget(vertices);
    mem::forget(indices);
    result
}

fn make_error_result(code: TruckErrorCode, message: impl Into<String>) -> *mut TruckMeshResult {
    let error_message = make_c_string(message.into())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut());

    let result = TruckMeshResult {
        vertices: ptr::null_mut(),
        vertex_count: 0,
        vertex_capacity: 0,
        indices: ptr::null_mut(),
        index_count: 0,
        index_capacity: 0,
        volume: 0.0,
        surface_area: 0.0,
        bbox_min_x: 0.0,
        bbox_min_y: 0.0,
        bbox_min_z: 0.0,
        bbox_max_x: 0.0,
        bbox_max_y: 0.0,
        bbox_max_z: 0.0,
        watertight: 0,
        error_code: code as i32,
        error_message,
    };

    Box::into_raw(Box::new(result))
}

fn make_c_string(mut message: String) -> Option<CString> {
    if message.is_empty() {
        message = String::from("unknown error");
    }
    if message.contains('\0') {
        message = message.replace('\0', " ");
    }

    match CString::new(message) {
        Ok(text) => Some(text),
        Err(_) => CString::new("unknown error").ok(),
    }
}
