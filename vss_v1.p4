/* Very Simple Switch on v1model architecture on bmv2-sss target */

#include <core.p4>
#include <v1model.p4>

typedef bit<48> EthernetAddress;
typedef bit<32> IPv4Address;
typedef bit<9> PortId;

/* special input port values */
const PortId RECIRCULATE_IN_PORT = 0xD;
const PortId CPU_IN_PORT = 0xE;

/* special output port values for outgoing packet */
const PortId DROP_PORT = 0xF;
const PortId CPU_OUT_PORT = 0xE;
const PortId RECIRCULATE_OUT_PORT = 0xD;

//Standard Ethernet header
header Ethernet_h {
	EthernetAddress dstAddr;
	EthernetAddress srcAddr;
	bit<16> 		etherType;
}

// IPv4 header (without options)
header IPv4_h {
	bit<4> version;
	bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    IPv4Address srcAddr;
    IPv4Address dstAddr;
}

// Structure of parsed headers
struct Parsed_packet {
	Ethernet_h	ethernet;
	IPv4_h 		ip;
}

// Metadata structure for the Parser/MAP/Deparser
struct empty_metadata_t {
	bit<16> test; //not used for VSS
}


// User-defined errors that may be signaled during parsing
error {
	IPv4OptionsNotSupported,
	IPv4IncorrectVersion,
	IPv4ChecksumError
}

struct metadata {
	empty_metadata_t empty_metadata;
	IPv4Address nextHop;  //used in ingress pipeline
  bit<9> egress_port;
//	error parseError;
}


// Why bother creating an action that just does one primitive action?
// That is, why not just use 'mark_to_drop' as one of the possible
// actions when defining a table?  Because the P4_16 compiler does not
// allow primitive actions to be used directly as actions of tables.
// You must use 'compound actions', i.e. ones explicitly defined with
// the 'action' keyword like below.

action my_drop() {
	mark_to_drop();  
}

// Parser section

parser TopParser(packet_in b,
					out Parsed_packet p,
					inout metadata meta,
					inout standard_metadata_t standard_metadata)
{
	const bit<16> ETHERTYPE_IPV4 = 16w0x0800;

	state start {
		b.extract(p.ethernet);
		transition select(p.ethernet.etherType) {
			ETHERTYPE_IPV4: parse_ipv4;
			// no default rule: all other packets rejected
		}
	}

	state parse_ipv4 {
		b.extract (p.ip);
		//verify(p.ip.version == 4w4, metadata.parseError.IPv4IncorrectVersion);
		//verify(p.ip.ihl == 4w5, metadata.parseError.IPv4OptionsNotSupported); 
		transition accept;
	}
}

control verifyChecksum(inout Parsed_packet p, inout metadata meta) {
	apply {
		verify_checksum(p.ip.isValid() && p.ip.ihl == 5,
			{ p.ip.version,
				p.ip.ihl,
				p.ip.diffserv,
				p.ip.totalLen,
				p.ip.identification,
				p.ip.flags,
				p.ip.fragOffset,
				p.ip.ttl,
				p.ip.protocol,
				p.ip.srcAddr,
				p.ip.dstAddr },
			p.ip.hdrChecksum, HashAlgorithm.csum16);
	}
}


control ingress(inout Parsed_packet headers,
				inout metadata meta,
				inout standard_metadata_t standard_metadata) {

	

	/**
      * Set the next hop and the output port.
      * Decrements ipv4 ttl field.
      * @param ivp4_dest ipv4 address of next hop
      * @param port output port **Equivalent to intf in demo1
      */
    action Set_nhop(IPv4Address ipv4_dest, PortId port) {
        meta.nextHop = ipv4_dest;
        headers.ip.ttl = headers.ip.ttl-1;
        standard_metadata.egress_spec = port;
        meta.egress_port = port;  //save on metadata so that can be looked up in egress.smac table
    }

    /**
      * Computes address of next Ipv4 hop and output port
      * based on the Ipv4 destination of the current packet.
      * Decrements packet Ipv4 TTL.
      * @param nextHop IPv4 address of next hop
      */
    table ipv4_match {
        key = { headers.ip.dstAddr : lpm; } //longest-prefix match
        actions = {
            my_drop();
            Set_nhop;
        }
        size = 1024;
        default_action = my_drop;
    }

    /**
      * Send the packet to the CPU port
      */
    action Send_to_cpu() { 
    	standard_metadata.egress_spec = CPU_OUT_PORT; 
    }

    /**
      * Check packet TTL and send to CPU if expired.
      */
    table check_ttl {
        key = { headers.ip.ttl : exact; } //exact match
        actions = { Send_to_cpu; NoAction; }
        const default_action = NoAction(); // defined in core.p4
    }

    /**
      * Set the destination MAC address of the packet
      * @param dmac destination MAC address.
      */
    action Set_dmac(EthernetAddress dmac)
    { headers.ethernet.dstAddr = dmac; }

    /**
      * Set the destination Ethernet address of the packet
      * based on the next hop IP address.
      * @param nextHop IPv4 address of next hop.
      */
    table dmac {
        key = { meta.nextHop : exact; }
        actions = {
            my_drop;
            Set_dmac;
        }
        size = 1024;
        default_action = my_drop;
    }

    apply {
    	if (standard_metadata.parser_error != error.NoError) {
    		my_drop();  //invoke drop directly
    		return;
    	}

    	ipv4_match.apply(); // Match result will go into nextHop
    	check_ttl.apply();
    	dmac.apply();
    }
}

control egress(inout Parsed_packet headers,
				inout metadata meta,
				inout standard_metadata_t standard_metadata) {
	/**
      * Set the source MAC address.
      * @param smac: source MAC address to use
      */
    action Set_smac(EthernetAddress smac) { 
    	headers.ethernet.srcAddr = smac;
    }

    /**
      * Set the source mac address based on the output port.
      */
    table smac {
        key = { meta.egress_port : exact; }
        actions = {
            my_drop;
            Set_smac;
        }
        size = 16;
        default_action = my_drop;
    }

    apply {
    	smac.apply();
    }
}


control computeChecksum(inout Parsed_packet p, inout metadata meta) {
	apply {
		update_checksum(p.ip.isValid() && p.ip.ihl == 5,
			{ p.ip.ihl,
				p.ip.diffserv,
				p.ip.totalLen,
				p.ip.identification,
				p.ip.flags,
				p.ip.fragOffset,
				p.ip.ttl,
				p.ip.protocol,
				p.ip.srcAddr,
				p.ip.dstAddr },
			p.ip.hdrChecksum, HashAlgorithm.csum16);
	}
}

control TopDeparser(packet_out b, in Parsed_packet p) {
	apply {
		b.emit(p.ethernet);
		b.emit(p.ip);
	}
}


// Instantiate the top-level VSS package

V1Switch(TopParser(),
		 verifyChecksum(),
		 ingress(),
		 egress(),
		 computeChecksum(),
		 TopDeparser()) main;

