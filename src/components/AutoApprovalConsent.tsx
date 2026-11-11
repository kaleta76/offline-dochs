import { useId, useState } from "react";
import { AUTO_APPROVAL_DAYS, AUTO_APPROVAL_PER_DAY } from "@/lib/auto-approval";
import { Button } from "@/components/ui/button";

/**
 * Upozornenie a súhlas vedúceho pred zapnutím automatického schvaľovania opráv. Zapnutie sa nespraví jedným kliknutím:
 * vedúci si najprv prečíta, čo voľba znamená, a potvrdí to začiarknutím. Vypnutie súhlas nepotrebuje (je vždy bezpečné).
 * Databáza eviduje len to, kto voľbu zapol a kedy; text súhlasu je len v aplikácii.
 */
export function AutoApprovalConsent({
  name,
  busy,
  onConfirm,
  onCancel,
}: {
  name: string;
  busy: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const [agreed, setAgreed] = useState(false);
  const titleId = useId();
  const checkId = useId();

  return (
    <div
      role="group"
      aria-labelledby={titleId}
      className="w-full space-y-3 rounded-sm border-2 border-destructive bg-background p-3"
    >
      <h3 id={titleId} className="text-sm font-bold">
        Zapnúť automatické schvaľovanie opráv pre {name}?
      </h3>
      <p className="text-sm">Prečítajte si, čo to znamená:</p>
      <ul className="list-disc space-y-1.5 pl-5 text-sm">
        <li>
          Žiadosti o opravu, ktoré {name} podá <strong>zo svojho overeného zariadenia</strong>, sa
          schvália <strong>okamžite a bez vášho rozhodnutia</strong>: príchod, odchod a prerušenia
          bez príznaku „vyžaduje schválenie“. Najviac {AUTO_APPROVAL_PER_DAY} za deň a nie staršie
          ako {AUTO_APPROVAL_DAYS} dní.
        </li>
        <li>
          Schválená oprava vytvorí razenie, ktoré sa započíta do dochádzky a odíde do mzdového
          exportu. <strong>Zodpovednosť za tieto opravy ostáva na vás</strong> ako na vedúcom,
          rovnako ako keby ste ich schválili ručne.
        </li>
        <li>
          Ručne schvaľujete ďalej: žiadosti z neoverených zariadení, schvaľovanie zariadení a
          žiadosti, ktoré čakajú už teraz.
        </li>
        <li>
          Kontrola: zoznam automaticky schválených opráv za posledných {AUTO_APPROVAL_DAYS} dní máte
          nižšie a každé takéto razenie viete zneplatniť.
        </li>
        <li>
          Voľba platí, kým ju nevypnete (smie ju vypnúť aj správca). Pri zmene vedúceho zamestnanca
          zanikne. Eviduje sa, kto ju zapol a kedy.
        </li>
      </ul>
      <label htmlFor={checkId} className="flex items-start gap-2 text-sm font-semibold">
        <input
          id={checkId}
          type="checkbox"
          className="mt-1"
          checked={agreed}
          onChange={(e) => setAgreed(e.target.checked)}
        />
        <span>
          Rozumiem, že opravy zamestnanca {name} sa budú schvaľovať automaticky a že za ne
          zodpovedám ako vedúci.
        </span>
      </label>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={!agreed || busy} onClick={onConfirm}>
          Zapnúť automatické schvaľovanie
        </Button>
        <Button size="sm" variant="outline" disabled={busy} onClick={onCancel}>
          Zrušiť
        </Button>
      </div>
    </div>
  );
}
