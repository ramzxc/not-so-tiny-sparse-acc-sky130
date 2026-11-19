"""Fold explicit SRAM load/store setup into compact instructions, preserving order.

Input/output words may carry a phase tag above bit 15. No arithmetic or fences
are removed. Unknown addresses (notably after MICRO_RUN) prevent folding until
both address halves have been supplied. The original compiler can still emit
ordinary instructions for other backends.
"""

def compact_sram(tagged):
    out=[];address=0;known=0;i=0
    while i<len(tagged):
        value=tagged[i];word=value&65535;phase=value>>16
        if word in (0x8000,0x8400,0x9000):
            j=i+1;a=address;k=known
            while j<len(tagged) and (tagged[j]&65535)>>13==1 and tagged[j]>>16==phase:
                w=tagged[j]&65535
                if w&0x1000:a=(a&4095)|((w&4095)<<12);k|=2
                else:a=(a&0xfff000)|(w&4095);k|=1
                j+=1
            if (j<len(tagged) and tagged[j]>>16==phase and
                tagged[j]&65535==(0x5400 if word==0x9000 else 0x4400) and
                k==3 and a<1024 and not a&1):
                kind={0x8000:0,0x8400:1,0x9000:10}[word]
                out.append((phase<<16)|0xe000|(kind<<9)|(a>>1))
                address=a;known=k;i=j+1;continue
        opcode=word>>13
        if opcode==1:
            if word&0x1000:address=(address&4095)|((word&4095)<<12);known|=2
            else:address=(address&0xfff000)|(word&4095);known|=1
        elif opcode==5 and (word>>10)&7==5:known=0
        elif opcode==2 and word&0x100:
            if known==3:address=min(0xffffff,address+2)
            else:known=0
        out.append(value);i+=1
    return out
