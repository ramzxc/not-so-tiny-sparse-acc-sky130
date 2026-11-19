#!/usr/bin/env python3
"""UART input host for the PSRAM-program interface (pyserial only for the CLI).

MCU/board provisioning must finish before opening this session. READY credits
acknowledge receive capacity, not numerical output. The final credit follows
program drain; retain it for the next input frame.
"""
import argparse
from pathlib import Path

class StreamHost:
    def __init__(self,port):
        self.port=port;self.credit=False;self.input_bytes=None
    def wait_ready(self):
        if not self.credit:
            value=self.port.read(1)
            if value!=b'\x01':raise TimeoutError(f'Expected READY 01, got {value!r}; inspect error pin/reset on a fault')
            self.credit=True
    def word(self,value):
        if not 0<=value<=65535:raise ValueError('UART word outside 16 bits')
        self.wait_ready();self.credit=False
        if self.port.write(value.to_bytes(2,'little'))!=2:raise OSError('short UART write')
    def configure(self,program_base,program_words,input_base,input_bytes):
        if program_base<0 or program_base%2 or not 1<=program_words<=65535 or program_base+2*program_words>0x800000:
            raise ValueError('program must fit in PSRAM A and start at an even address')
        if input_base<0 or input_base>=1024 or input_base%2 or not 0<=input_bytes<=1024 or input_base+input_bytes+(input_bytes%2)>1024:
            raise ValueError('padded input must fit in SRAM at an even address')
        for value in (0xf100,program_base&65535,program_base>>16,program_words,input_base,input_bytes):self.word(value)
        self.wait_ready();self.input_bytes=input_bytes
    def run(self,payload=b''):
        if self.input_bytes is None:raise ValueError('configure first')
        if len(payload)!=self.input_bytes:raise ValueError('input length differs from configuration')
        self.word(0xf200 if payload else 0xf300)
        data=payload+b'\0'*(len(payload)%2)
        for i in range(0,len(data),2):self.word(int.from_bytes(data[i:i+2],'little'))
        self.wait_ready()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('port');p.add_argument('--baud',type=int,default=115200)
    p.add_argument('--program-base',type=lambda x:int(x,0),required=True)
    p.add_argument('--program-words',type=int,required=True)
    p.add_argument('--input-base',type=lambda x:int(x,0),default=768)
    p.add_argument('--input-bytes',type=int,required=True)
    p.add_argument('--inputs',type=Path,required=True);p.add_argument('--timeout',type=float,default=10)
    args=p.parse_args();data=args.inputs.read_bytes()
    if args.input_bytes<=0 or len(data)%args.input_bytes:p.error('file must contain complete nonempty frames')
    import serial
    with serial.Serial(args.port,args.baud,timeout=args.timeout,write_timeout=args.timeout) as port:
        host=StreamHost(port);host.configure(args.program_base,args.program_words,args.input_base,args.input_bytes)
        for i in range(0,len(data),args.input_bytes):host.run(data[i:i+args.input_bytes])
    print(f'Completed {len(data)//args.input_bytes} input frames')
if __name__=='__main__':main()
