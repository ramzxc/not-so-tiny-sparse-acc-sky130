"""Experimental sense amplifier with a local non-inverting output buffer."""
from openram import OPTS
from openram.base import design, vector
from openram.sram_factory import factory

class sense_amp_buffered(design):
    def __init__(self, name):
        super().__init__(name)
        for pin, kind in [('bl','INPUT'),('br','INPUT'),('dout','OUTPUT'),('en','INPUT'),('vdd','POWER'),('gnd','GROUND')]:
            self.add_pin(pin, kind)
        self.amp = factory.create(module_type='sense_amp_leaf')
        self.buf = factory.create(module_type='pbuf', size=8)
        self.sa = self.add_inst(name='sense', mod=self.amp)
        self.connect_inst(['bl','br','sense_out','en','vdd','gnd'])
        self.ob = self.add_inst(name='output_buffer', mod=self.buf)
        self.connect_inst(['sense_out','dout','vdd','gnd'])
        if OPTS.netlist_only: return
        self.sa.place(vector(0,0))
        self.ob.place(vector(3.5,0.3))
        self.width=self.ob.rx()
        self.height=self.amp.height
        for pin in ['bl','br','en']:
            self.copy_layout_pin(self.sa,pin)
        a=self.sa.get_pin('dout').center()
        b=self.ob.get_pin('A').center()
        self.add_via_stack_center(from_layer=self.sa.get_pin('dout').layer,to_layer='m2',offset=a)
        self.add_via_stack_center(from_layer=self.ob.get_pin('A').layer,to_layer='m2',offset=b)
        self.add_path('m2',[a,vector(2.9,a.y),vector(2.9,b.y),b])
        self.copy_layout_pin(self.ob,'Z','dout')
        for net,y in [('gnd',1.0),('vdd',10.5)]:
            for inst in [self.sa,self.ob]:
                pins=list(inst.get_pins(net))
                anchor=vector(pins[0].center().x,y)
                for pin in pins:
                    c=pin.center()
                    self.add_via_stack_center(from_layer=pin.layer,to_layer='m2',offset=c)
                    self.add_path('m2',[c,vector(c.x,y),anchor])
                self.add_via_stack_center(from_layer='m2',to_layer='m3',offset=anchor)
            self.add_layout_pin_segment_center(text=net,layer='m3',start=vector(0,y),end=vector(self.width,y))
        self.add_boundary()
    def get_bl_names(self): return 'bl'
    def get_br_names(self): return 'br'
    @property
    def dout_name(self): return 'dout'
    @property
    def en_name(self): return 'en'
    def get_enable_name(self): return 'en'
