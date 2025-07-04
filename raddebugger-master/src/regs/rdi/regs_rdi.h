// Copyright (c) Epic Games Tools
// Licensed under the MIT license (https://opensource.org/license/mit/)

#ifndef REGS_RDI_H
#define REGS_RDI_H

internal RDI_RegCode regs_rdi_code_from_arch_reg_code(Arch arch, REGS_RegCode code);
internal REGS_RegCode regs_reg_code_from_arch_rdi_code(Arch arch, RDI_RegCode reg);

#endif //REGS_RDI_H
