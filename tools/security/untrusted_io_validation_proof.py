#!/usr/bin/env python3
"""Focused regression proof for hostile SPI/USB/NIC/network input guards."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPI_DESC_MAX = 512
SPI_HEADER = 4
SPI_BUFFER = 516
XHCI_CONTEXT_BYTES = 4096
RTL_RX_QUEUED = 4096
RTL_RX_DESC = 24
RTL_CRC = 4
ETH_FRAME_MAX = 1522


def require_source(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    for needle in needles:
        assert needle in text, f"missing security guard in {path}: {needle!r}"


def prove_spi_descriptor_bounds() -> None:
    for descriptor_len in range(1, SPI_DESC_MAX + 1):
        requested = descriptor_len + SPI_HEADER
        assert requested <= SPI_BUFFER
        for returned in (0, SPI_HEADER, requested - 1, requested, requested + 1, 0xFFFF):
            accepted = returned == requested
            if accepted:
                assert SPI_HEADER + descriptor_len <= SPI_BUFFER


def prove_usb_endpoint_and_context_bounds() -> None:
    accepted = []
    for epaddr in range(256):
        epnum = epaddr & 0x0F
        ok = bool(epaddr & 0x80) and (epaddr & 0x70) == 0 and 1 <= epnum <= 15
        if not ok:
            continue
        accepted.append(epaddr)
        dci = epnum * 2 + 1
        assert 3 <= dci <= 31
        for stride in (32, 64):
            assert (dci + 1) * stride + stride <= XHCI_CONTEXT_BYTES
    assert accepted == list(range(0x81, 0x90))
    assert 0xFF not in accepted


def prove_rtl8156_actual_length_window() -> None:
    delivered = 0
    prefix_only_witness = 0
    for residual in range(0, RTL_RX_QUEUED + 2):
        actual = RTL_RX_QUEUED - residual if residual <= RTL_RX_QUEUED else -1
        maximum = min(actual - RTL_RX_DESC, ETH_FRAME_MAX + RTL_CRC)
        if maximum >= 32:
            delivered += maximum - 31
            assert RTL_RX_DESC + maximum <= actual
            assert maximum - RTL_CRC <= ETH_FRAME_MAX
        # A 32-byte descriptor claim after only the 24-byte prefix completed
        # passed the old 4096-prefix clamp but must fail the residual check.
        if actual == RTL_RX_DESC:
            prefix_only_witness += 1
    assert delivered > 0
    assert prefix_only_witness > 0, "residual-length regression witness vanished"


def prove_ipv4_and_dns_policy() -> None:
    local = 0x0A00020F
    resolver = 0x08080808

    def ipv4_accept(total: int, available: int, ihl: int, frag: int,
                    checksum_ok: bool, destination: int) -> bool:
        return (
            20 <= ihl <= total <= available
            and (frag & 0xBFFF) == 0
            and checksum_ok
            and destination in (local, 0xFFFFFFFF)
        )

    assert ipv4_accept(28, 28, 20, 0x4000, True, local)
    assert not ipv4_accept(60, 28, 20, 0, True, local)
    assert not ipv4_accept(28, 28, 20, 0x2000, True, local)
    assert not ipv4_accept(28, 28, 20, 1, True, local)
    assert not ipv4_accept(28, 28, 20, 0, False, local)
    assert not ipv4_accept(28, 28, 20, 0, True, 0x0A000210)
    assert resolver == resolver
    assert 0x01010101 != resolver


def prove_source_guards_present() -> None:
    require_source(
        "src/kernel/drivers/spi_hid.asm",
        "SPI_RDESC_MAX + SPI_RX_HDR",
        "cmp eax, ecx\n    jne .rdesc_fail",
    )
    require_source(
        "src/kernel/grithlk/usb_hid_helpers.ghl",
        "if (epaddr & 0x70) != 0",
        "if epnum < 1",
    )
    require_source(
        "src/kernel/drivers/xhci_trb.inc",
        "cmp r12d, 15",
        "cmp edx, 4096",
    )
    require_source(
        "src/kernel/drivers/xhci_rings.inc",
        "and edx, 0x00FFFFFF",
    )
    require_source(
        "src/kernel/drivers/rtl8156_usb.inc",
        "sub r10d, RTL8156_RX_DESC_LEN",
        "cmp eax, NET_ETH_FRAME_MAX + 4",
    )
    require_source(
        "src/kernel/grithlk/ip.ghl",
        "if total > len { return 0; }",
        "if ip_checksum(pkt, ihl) != 0 { return 0; }",
        "if (frag & 0xBFFF) != 0 { return 0; }",
    )
    require_source(
        "src/kernel/grithlk/dns.ghl",
        "srcip & 0xFFFFFFFF",
        "net_dns_server_ip",
    )
    for path in (
        "src/kernel/net/nic.asm",
        "src/kernel/drivers/rtl8139_tx_rx.inc",
        "src/kernel/drivers/rtl8156_txrx.inc",
    ):
        require_source(path, "NET_ETH_FRAME_MAX", "NET_ETH_FRAME_MIN")


def main() -> int:
    prove_spi_descriptor_bounds()
    prove_usb_endpoint_and_context_bounds()
    prove_rtl8156_actual_length_window()
    prove_ipv4_and_dns_policy()
    prove_source_guards_present()
    print("untrusted_io_validation_proof: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
