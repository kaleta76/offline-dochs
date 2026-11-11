import { useState, type ReactNode } from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

const trigger =
  "rounded-none px-4 py-2 font-bold uppercase tracking-widest data-[state=active]:bg-foreground data-[state=active]:text-background data-[state=active]:shadow-none";

/**
 * Správa má dve karty. „Prevádzka“ je pre bežnú prácu (sekretárka HR, správca) a je vždy zapnutá. „Servis a testovanie“ sa ukáže
 * len vtedy, keď ju správa odkryje (pozri src/lib/service-visibility.ts); inak sa nevykreslí ani záložka, ani obsah, takže sa
 * ani nespustia jej dopyty na server. Obsah karty Prevádzka ostáva načítaný aj počas pobytu v Servise (nestratia sa rozpísané údaje).
 */
export function AdminTabs({
  showService,
  openService,
  operation,
  service,
}: {
  showService: boolean;
  openService: boolean;
  operation: ReactNode;
  service: ReactNode;
}) {
  // Adresu (?servis=1) čítame v prehliadači až po prvom vykreslení, preto predvolená karta nie je počiatočný stav, ale odvodená hodnota:
  // kým človek sám nevyberie, platí predvolená.
  const [picked, setPicked] = useState<"operation" | "service" | null>(null);
  const active = !showService ? "operation" : (picked ?? (openService ? "service" : "operation"));

  if (!showService) return <div className="space-y-8">{operation}</div>;

  return (
    <Tabs
      value={active}
      onValueChange={(v) => setPicked(v === "service" ? "service" : "operation")}
    >
      <TabsList className="mb-6 h-auto rounded-sm border-2 border-foreground bg-card p-0">
        <TabsTrigger value="operation" className={trigger}>
          Prevádzka
        </TabsTrigger>
        <TabsTrigger value="service" className={trigger}>
          Servis a testovanie
        </TabsTrigger>
      </TabsList>
      <TabsContent
        value="operation"
        forceMount
        hidden={active !== "operation"}
        className="space-y-8"
      >
        {operation}
      </TabsContent>
      <TabsContent value="service" className="space-y-8">
        <p className="rounded-sm border-2 border-destructive bg-card p-3 text-sm">
          <strong>Nie je pre bežnú prevádzku.</strong> Tu sú nastavenia, ktoré menia výpočet, import
          a testovanie, a nástroje na zrušenie testovacej organizácie. Ak neviete, na čo slúžia, nič
          tu nemeňte.
        </p>
        {service}
      </TabsContent>
    </Tabs>
  );
}
