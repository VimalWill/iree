// Copyright 2024 The IREE Authors
//
// Licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef IREE_COMPILER_CODEGEN_DIALECT_GPU_IREEGPUATTRS
#define IREE_COMPILER_CODEGEN_DIALECT_GPU_IREEGPUATTRS

include "iree/compiler/Codegen/Dialect/GPU/IR/IREEGPUDialect.td"
include "iree/compiler/Codegen/Dialect/GPU/IR/IREEGPUInterfaces.td"
include "mlir/IR/OpBase.td"
include "mlir/IR/AttrTypeBase.td"
include "mlir/IR/EnumAttr.td"

//===----------------------------------------------------------------------===//
// Base MMA Vector Layout Attributes
//===----------------------------------------------------------------------===//

class IREEGPU_MmaVectorLayoutAttr<string attrname, string mmaintrinsic> :
    AttrDef<IREEGPU_Dialect, attrname, [
  DeclareAttrInterfaceMethods<IREEGPU_MmaInterfaceAttr, [
    "getABCElementTypes",
    "getABCVectorTypes",
    "getContractionLayout",
    "getMNKShape",
    "getSubgroupSize",
  ]>
]> {
  let cppNamespace = "::mlir::iree_compiler::IREE::GPU";

  string baseDescription = [{
    Attribute describing a particular shape of matrix-multiply and accumulate
    instruction. Abstractly, all attributes of this type represent the following
    unit of arithmetic for matrices A, B, and C.

    ```
      C += A x B
    ```

    Where the shape of matrix `A` is `[m, k]`, `B` is `[k, n]`, and
    `C` is `[m, n]`. This intentionally leaves the layout information abstract
    and uses interface methods to materialize layout information only when
    needed. The shape of the mma intrinsic is stored explicitly here as that
    information is queried frequently.

    The element types for this particular mma intrinsic are |aType|, |bType|,
    and |cType| for matrices `A`, `B`, and `C` respectively.

    ######

  }];


  let parameters = (ins
    mmaintrinsic:$intrinsic,
    "int64_t":$mSize,
    "int64_t":$nSize,
    "int64_t":$kSize,
    "::mlir::Type":$aType,
    "::mlir::Type":$bType,
    "::mlir::Type":$cType
  );

  string baseExtraClassDeclaration = [{
    ::std::tuple<Type, Type, Type> getABCElementTypes() {
      return ::std::make_tuple(getAType(), getBType(), getCType());
    }

    ::std::tuple<int64_t, int64_t, int64_t> getMNKShape() {
      return ::std::make_tuple(getMSize(), getNSize(), getKSize());
    }
  }];
}

class IREEGPU_I32MmaEnumAttr<string name, string summary, list<I32EnumAttrCase> cases>
    : I32EnumAttr<name, summary, cases> {
  let cppNamespace = "::mlir::iree_compiler::IREE::GPU";
  let genSpecializedAttr = 0;
}

class IREEGPU_MmaEnumAttr<EnumAttrInfo enumInfo, string name = "">
  : EnumAttr<IREEGPU_Dialect, enumInfo, name>;

//===----------------------------------------------------------------------===//
// MMA Attributes
//===----------------------------------------------------------------------===//

def MFMA_F16_16x16x16_F32 : I32EnumAttrCase<"MFMA_F16_16x16x16_F32", 0>;
def MFMA_F16_32x32x8_F32 : I32EnumAttrCase<"MFMA_F16_32x32x8_F32", 1>;
def WMMA_F16_16x16x16_F32 : I32EnumAttrCase<"WMMA_F16_16x16x16_F32", 2>;

def IREEGPU_MMAIntrinsic : IREEGPU_I32MmaEnumAttr<"MMAIntrinsic",
    "Descriptor for different MMA intrinsics", [
      MFMA_F16_16x16x16_F32,
      MFMA_F16_32x32x8_F32,
      WMMA_F16_16x16x16_F32
    ]>;

def INVALID_COMPUTE_TYPE : I32EnumAttrCase<"INVALID", 0>;
def MFMA_COMPUTE_TYPE : I32EnumAttrCase<"MFMA", 1>;
def WMMA_COMPUTE_TYPE : I32EnumAttrCase<"WMMA", 2>;
def IREEGPU_MMAComputeType : IREEGPU_I32MmaEnumAttr<"MMAComputeType",
    "Descriptor for different types of MMA operations", [
      INVALID_COMPUTE_TYPE,
      MFMA_COMPUTE_TYPE,
      WMMA_COMPUTE_TYPE
    ]>;

def IREEGPU_MMAIntrinsicAttr
  : IREEGPU_MmaEnumAttr<IREEGPU_MMAIntrinsic, "mma_intrinsic">;

def IREEGPU_MMAAttr : IREEGPU_MmaVectorLayoutAttr<"MMA", "MMAIntrinsicAttr"> {
  let mnemonic = "mma_layout";
  let cppNamespace = "::mlir::iree_compiler::IREE::GPU";

  let description = !strconcat(baseDescription, [{
    This mma variant describes configurations for MMA ops. The |intrinsic|
    field specifies which particular MMA intrinsic this refers to, with each
    intrinsic implicating a specific MNK shape and operand types. The intrinsic
    enum name describes these fields as

    <InputType>_MxNxK_<CType>

    Where the element type for the `A` and `B` matrices are both `InputType`.
  }]);

  let hasCustomAssemblyFormat = 1;

  let skipDefaultBuilders = 1;
  let builders = [
    AttrBuilder<(ins "MMAIntrinsic":$intrinsic)>
  ];

  let extraClassDeclaration = !strconcat(baseExtraClassDeclaration, [{
    int64_t getBlockSize() const;
    MMAComputeType getComputeType() const;
    SmallVector<int64_t> getADataDuplicate() const;
    SmallVector<int64_t> getBDataDuplicate() const;
    SmallVector<int64_t> getCDataDuplicate() const;

    // Partial nested layout for an MMA intrinsic's matrix input/output inside
    // a single subgroup.
    //
    // Note that this is just a container used by the following methods; it can
    // contain both the shape and the order.
    struct SingleSubgroupLayout {
      SmallVector<int64_t, 2> outer;
      SmallVector<int64_t, 2> thread;
      SmallVector<int64_t, 2> element;
    };

    // Returns the A/B/C matrix's partial nested layout shape inside a single
    // subgroup. Shape at each outer/thread/element level is a 2-D value,
    // following canonical matmul order--(M, K) for A, (K, N) for B, and
    // (M, N) for C.
    SingleSubgroupLayout getASingleSubgroupLayoutCount() const;
    SingleSubgroupLayout getBSingleSubgroupLayoutCount() const;
    SingleSubgroupLayout getCSingleSubgroupLayoutCount() const;

    // Returns the A/B/C matrix's partial nested layout order inside a single
    // subgroup. Order at each outer/thread/element level is a 2-value
    // permuation vector, following canonical matmul order--(M, K) for A,
    // (K, N) for B, and (M, N) for C.
    SingleSubgroupLayout getASingleSubgroupLayoutOrder() const;
    SingleSubgroupLayout getBSingleSubgroupLayoutOrder() const;
    SingleSubgroupLayout getCSingleSubgroupLayoutOrder() const;
  }]);
}

//===----------------------------------------------------------------------===//
// MMA schedule Attributes
//===----------------------------------------------------------------------===//

def IREEGPU_MmaScheduleAttr : AttrDef<IREEGPU_Dialect, "MMASchedule"> {
  let mnemonic = "mma_schedule";
  let cppNamespace = "::mlir::iree_compiler::IREE::GPU";

  string description = [{
    A schedule of MMA intrinsic instruction and various levels of tile sizes
    to solve a specific contraction problem.
  }];


  let parameters = (ins
    "::mlir::iree_compiler::IREE::GPU::MmaInterfaceAttr":$intrinsic,
    "int64_t":$subgroup_m_count,
    "int64_t":$subgroup_n_count,
    "int64_t":$subgroup_m_tile_count,
    "int64_t":$subgroup_n_tile_count,
    "int64_t":$subgroup_k_tile_count
  );

  let assemblyFormat = "`<` struct(params) `>`";

  let extraClassDeclaration = [{
    // Returns the A/B/C matrix concrete layout targeting |contractOp|.
    ::std::optional<::std::tuple<VectorExt::VectorLayoutInterface,
                                 VectorExt::VectorLayoutInterface,
                                 VectorExt::VectorLayoutInterface>>
      getContractionLayout(::mlir::vector::ContractionOp contractOp) const;
  }];
}


#endif // IREE_COMPILER_CODEGEN_DIALECT_GPU_IREEGPUATTRS
